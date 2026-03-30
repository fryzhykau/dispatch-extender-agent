/**
 * keep-awake.js — Prevents Windows from sleeping while the relay or worker is active.
 *
 * Uses a persistent PowerShell process that calls SetThreadExecutionState
 * with ES_CONTINUOUS | ES_SYSTEM_REQUIRED every 60 seconds.
 *
 * Usage:
 *   import { startKeepAwake, stopKeepAwake } from '../lib/keep-awake.js';
 *   const handle = startKeepAwake();
 *   // ... later ...
 *   stopKeepAwake(handle);
 */

import { spawn, exec } from 'node:child_process';

const PS_SCRIPT = `
try {
    $code = '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    $t = Add-Type -MemberDefinition $code -Name 'KA' -Namespace 'Win32' -PassThru
    while ($true) {
        [void]$t::SetThreadExecutionState([uint32]0x80000001)
        Start-Sleep -Seconds 60
    }
} catch {
    Write-Error "SetThreadExecutionState failed: $_"
    exit 1
}
`.trim();

const PS_CLEAR_SCRIPT = `
try {
    $code = '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);'
    $t = Add-Type -MemberDefinition $code -Name 'KAClear' -Namespace 'Win32Clear' -PassThru
    [void]$t::SetThreadExecutionState([uint32]0x80000000)
} catch {
    Write-Error "Failed to clear execution state: $_"
}
`.trim();

/**
 * Start preventing sleep. Returns a handle object with a `stop()` method.
 * @param {{ enabled?: boolean }} [options]
 * @returns {{ stop: () => void }}
 */
export function startKeepAwake(options = {}) {
  const enabled = options.enabled !== undefined ? options.enabled : true;

  if (!enabled) {
    console.log('[keep-awake] Sleep prevention is disabled by configuration');
    return { stop() {} };
  }

  if (process.platform !== 'win32') {
    console.warn('[keep-awake] WARNING: Sleep prevention is only supported on Windows. No-op on this platform.');
    return { stop() {} };
  }

  console.log('[keep-awake] Starting sleep prevention (SetThreadExecutionState loop)');

  const child = spawn('powershell', ['-NoProfile', '-Command', PS_SCRIPT], {
    stdio: ['ignore', 'ignore', 'pipe'],
    windowsHide: true,
  });

  child.on('error', (err) => {
    console.warn('[keep-awake] Failed to spawn PowerShell process:', err.message);
    console.warn('[keep-awake] Sleep prevention unavailable — relay/worker will continue without it.');
  });

  if (child.stderr) {
    let stderrBuf = '';
    child.stderr.on('data', (chunk) => {
      stderrBuf += chunk.toString();
    });
    child.stderr.on('end', () => {
      if (stderrBuf.trim()) {
        console.warn('[keep-awake] PowerShell stderr:', stderrBuf.trim());
      }
    });
  }

  child.on('exit', (code) => {
    if (code !== null && code !== 0) {
      console.warn(`[keep-awake] PowerShell process exited with code ${code} — sleep prevention stopped but relay/worker will continue.`);
    }
  });

  // Prevent the child from keeping the Node process alive if it is the only
  // thing left. The caller is responsible for stopping it before exit.
  child.unref();

  return {
    stop() {
      stopKeepAwake(child);
    },
  };
}

/**
 * Stop preventing sleep. Kills the PowerShell loop process and clears the
 * execution state flags so that normal power management resumes.
 * @param {import('node:child_process').ChildProcess} child
 */
export function stopKeepAwake(child) {
  if (process.platform !== 'win32') {
    return;
  }

  console.log('[keep-awake] Stopping sleep prevention');

  // Kill the persistent loop
  try {
    if (child && !child.killed) {
      child.kill();
    }
  } catch {
    // Already dead — ignore.
  }

  // Clear the execution state flags so Windows can sleep again
  exec(
    `powershell -NoProfile -Command "${PS_CLEAR_SCRIPT.replace(/\r?\n/g, '; ')}"`,
    { windowsHide: true },
    (err) => {
      if (err) {
        console.warn('[keep-awake] Failed to clear execution state:', err.message);
      } else {
        console.log('[keep-awake] Sleep prevention stopped — normal power management restored');
      }
    }
  );
}
