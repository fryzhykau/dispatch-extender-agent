import fs, { readFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path, { dirname, join, resolve } from "node:path";
import WebSocket from "ws";

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const __dirname = dirname(fileURLToPath(import.meta.url));
const config = JSON.parse(
  readFileSync(join(__dirname, "worker-config.json"), "utf-8")
);

const { machineId, sharedSecret, defaultWorkingDir, allowedDirs, denyDirs, agentName, agentDescription, agentCapabilities } = config;
let coordinatorHost = config.coordinatorHost;
const tlsConfig = config.tls || { enabled: false };
const discoveryConfig = config.discovery || { enabled: false };
const MAX_OUTPUT_LENGTH = config.maxOutputLength ?? 1000000;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let ws = null;
let backoff = 1000; // current reconnect delay (ms)
const MAX_BACKOFF = 30_000;

let busy = false;
let runningChild = null; // the active claude subprocess
let killTimer = null; // timeout handle for task timeout
let keepAwakeHandle = null; // sleep prevention handle

// ---------------------------------------------------------------------------
// Logging helpers
// ---------------------------------------------------------------------------

function log(...args) {
  console.log(`[${new Date().toISOString()}] [${machineId}]`, ...args);
}

function logError(...args) {
  console.error(`[${new Date().toISOString()}] [${machineId}]`, ...args);
}

// ---------------------------------------------------------------------------
// WebSocket connection
// ---------------------------------------------------------------------------

function connect() {
  // Determine URL and TLS options
  let url = coordinatorHost;
  const wsOptions = {};

  if (tlsConfig.enabled) {
    // Switch ws:// to wss://
    url = url.replace(/^ws:\/\//, 'wss://');
    wsOptions.cert = readFileSync(join(__dirname, tlsConfig.certFile));
    wsOptions.key = readFileSync(join(__dirname, tlsConfig.keyFile));
    wsOptions.ca = readFileSync(join(__dirname, tlsConfig.caFile));
    wsOptions.rejectUnauthorized = true;
    log('TLS enabled — using WSS');
  }

  log(`Connecting to relay at ${url} ...`);
  ws = new WebSocket(url, wsOptions);

  ws.on("open", () => {
    log("Connected to relay — sending register");
    backoff = 1000; // reset on successful connect

    ws.send(
      JSON.stringify({
        type: "register",
        machineId,
        token: sharedSecret,
        agentName: agentName || null,
        agentDescription: agentDescription || null,
        agentCapabilities: agentCapabilities || [],
      })
    );
  });

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      logError("Received non-JSON message, ignoring");
      return;
    }

    if (msg.type === "task") {
      handleTask(msg);
      return;
    }

    // --- Respond to relay heartbeat pings ---
    if (msg.type === "ping") {
      send({
        type: "pong",
        machineId,
        timestamp: msg.timestamp,
        status: busy ? "busy" : "idle",
      });
      return;
    }
  });

  ws.on("close", () => {
    log("WebSocket closed");
    scheduleReconnect();
  });

  ws.on("error", (err) => {
    logError("WebSocket error:", err.message);
    // 'close' will fire after 'error', so reconnect is handled there.
  });
}

function scheduleReconnect() {
  log(`Reconnecting in ${backoff / 1000}s ...`);
  setTimeout(() => {
    connect();
    backoff = Math.min(backoff * 2, MAX_BACKOFF);
  }, backoff);
}

// ---------------------------------------------------------------------------
// Send helper (safe — checks readyState)
// ---------------------------------------------------------------------------

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  } else {
    logError("Cannot send — WebSocket not open. Message dropped:", obj);
  }
}

// ---------------------------------------------------------------------------
// Path validation
// ---------------------------------------------------------------------------

/**
 * Normalize a filesystem path: resolve `.` / `..`, strip trailing slashes,
 * and convert backslashes to forward slashes so comparisons are consistent.
 */
function normalizePath(p) {
  // resolve handles .., . and produces an absolute path
  let resolved = resolve(p);
  // convert backslashes to forward slashes
  resolved = resolved.replace(/\\/g, '/');
  // strip trailing slash (unless it's just a drive root like "C:/")
  resolved = resolved.replace(/\/+$/, '') || resolved;
  return resolved;
}

/**
 * Check whether `workingDir` is permitted by the allowedDirs / denyDirs lists.
 *
 * @param {string} workingDir - the directory to validate
 * @param {string[]} allowed  - directories the worker may operate in
 * @param {string[]} denied   - directories the worker must NOT operate in
 *                               (supports a single `*` wildcard segment)
 * @returns {{ allowed: boolean, reason: string }}
 */
function isPathAllowed(workingDir, allowed = [], denied = []) {
  const normalized = normalizePath(workingDir);

  // Check deny list first
  for (const denyPattern of denied) {
    const normalizedDeny = normalizePath(denyPattern).replace(/\*/g, '[^/]+');
    const denyRegex = new RegExp(`^${normalizedDeny}(/|$)`, 'i');
    if (denyRegex.test(normalized)) {
      return { allowed: false, reason: `Path falls under denied directory: ${denyPattern}` };
    }
  }

  // Check allow list
  if (allowed.length === 0) {
    return { allowed: true, reason: 'No allowedDirs configured — all paths accepted' };
  }

  for (const allowedDir of allowed) {
    const normalizedAllow = normalizePath(allowedDir);
    if (normalized.toLowerCase().startsWith(normalizedAllow.toLowerCase())) {
      return { allowed: true, reason: 'Path is under allowed directory' };
    }
  }

  return { allowed: false, reason: `Path is not under any allowed directory (allowed: ${allowed.join(', ')})` };
}

// ---------------------------------------------------------------------------
// Task handling
// ---------------------------------------------------------------------------

function handleTask(msg) {
  const { taskId, prompt, workingDir, timeout } = msg;

  // Reject if already busy
  if (busy) {
    log(`Busy — rejecting task ${taskId}`);
    send({
      type: "result",
      taskId,
      machineId,
      status: "error",
      output: "Worker is busy with another task",
      durationMs: 0,
    });
    return;
  }

  const cwd = workingDir || defaultWorkingDir;

  // Validate working directory against allow/deny lists
  const pathCheck = isPathAllowed(cwd, allowedDirs || [], denyDirs || []);
  if (!pathCheck.allowed) {
    log(`WARNING: Denied path attempt for task ${taskId}: "${cwd}" — ${pathCheck.reason}`);
    send({
      type: "result",
      taskId,
      machineId,
      status: "error",
      output: `Working directory denied: ${pathCheck.reason}`,
      durationMs: 0,
    });
    return;
  }

  // Validate that the directory actually exists
  if (!existsSync(cwd)) {
    log(`WARNING: Working directory does not exist for task ${taskId}: "${cwd}"`);
    send({
      type: "result",
      taskId,
      machineId,
      status: "error",
      output: `Working directory does not exist: ${cwd}`,
      durationMs: 0,
    });
    return;
  }

  busy = true;
  const startTime = Date.now();

  log(`Starting task ${taskId} in ${cwd}`);

  const child = spawn(
    "claude",
    ["--print", "--dangerously-skip-permissions", prompt],
    {
      cwd,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    }
  );
  runningChild = child;

  let stdout = "";
  let stderr = "";
  let stdoutTruncated = false;

  child.stdout.on("data", (chunk) => {
    if (stdoutTruncated) return;
    const text = chunk.toString();
    if (stdout.length + text.length > MAX_OUTPUT_LENGTH) {
      stdout = stdout.slice(0, MAX_OUTPUT_LENGTH) + text.slice(0, MAX_OUTPUT_LENGTH - stdout.length);
      stdout += "\n...[output truncated at 1MB]";
      stdoutTruncated = true;
      log(`WARNING: stdout for task exceeded ${MAX_OUTPUT_LENGTH} chars — truncating`);
      return;
    }
    stdout += text;
  });

  let stderrTruncated = false;
  child.stderr.on("data", (chunk) => {
    if (stderrTruncated) return;
    const text = chunk.toString();
    if (stderr.length + text.length > MAX_OUTPUT_LENGTH) {
      stderr += text.substring(0, MAX_OUTPUT_LENGTH - stderr.length);
      stderrTruncated = true;
      return;
    }
    stderr += text;
  });

  // Timeout handling
  const timeoutMs = timeout || 120_000; // default 2 min
  killTimer = setTimeout(() => {
    log(`Task ${taskId} timed out after ${timeoutMs}ms — killing process`);
    child.kill("SIGTERM");
    // Give it a moment, then force-kill
    setTimeout(() => {
      if (!child.killed) {
        child.kill("SIGKILL");
      }
    }, 3000);
  }, timeoutMs);

  child.on("close", (code) => {
    clearTimeout(killTimer);
    killTimer = null;
    runningChild = null;
    busy = false;

    const durationMs = Date.now() - startTime;

    // Determine if this was a timeout kill
    const timedOut = durationMs >= timeoutMs;

    let status;
    let output;

    if (timedOut) {
      status = "timeout";
      output = stdout || "(no output before timeout)";
    } else if (code !== 0) {
      status = "error";
      output = stderr || stdout || `Process exited with code ${code}`;
    } else {
      status = "done";
      output = stdout;
    }

    log(`Task ${taskId} finished — status=${status} duration=${durationMs}ms`);

    send({
      type: "result",
      taskId,
      machineId,
      status,
      output,
      durationMs,
    });
  });

  child.on("error", (err) => {
    clearTimeout(killTimer);
    killTimer = null;
    runningChild = null;
    busy = false;

    const durationMs = Date.now() - startTime;
    logError(`Task ${taskId} spawn error:`, err.message);

    send({
      type: "result",
      taskId,
      machineId,
      status: "error",
      output: `Spawn error: ${err.message}`,
      durationMs,
    });
  });
}

// ---------------------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------------------

function shutdown(signal) {
  log(`Received ${signal} — shutting down`);

  if (keepAwakeHandle) {
    keepAwakeHandle.stop();
    keepAwakeHandle = null;
  }

  if (killTimer) {
    clearTimeout(killTimer);
  }

  if (runningChild) {
    log("Killing running subprocess");
    runningChild.kill("SIGTERM");
  }

  if (ws) {
    ws.close();
  }

  process.exit(0);
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

// ---------------------------------------------------------------------------
// Start
// ---------------------------------------------------------------------------

async function start() {
  log("Agent relay starting");

  // Attempt UDP discovery if enabled and coordinatorHost is empty or "auto"
  if (discoveryConfig.enabled && (!coordinatorHost || coordinatorHost === "auto")) {
    log("Discovery enabled — listening for relay broadcast...");
    try {
      const { discoverRelay } = await import("./discovery.js");
      const broadcastPort = discoveryConfig.broadcastPort ?? 7071;
      const timeoutMs = discoveryConfig.timeoutMs ?? 15000;
      const relay = await discoverRelay(broadcastPort, timeoutMs, config.sharedSecret || '');
      const protocol = tlsConfig.enabled ? "wss" : "ws";
      coordinatorHost = `${protocol}://${relay.host}:${relay.port}`;
      log(`Discovered relay at ${coordinatorHost}`);
    } catch (err) {
      logError("Discovery failed:", err.message);
      coordinatorHost = config.coordinatorHost;
      if (!coordinatorHost || coordinatorHost === "auto") {
        logError("No fallback coordinatorHost configured — cannot connect");
        process.exit(1);
      }
      log(`Falling back to configured coordinatorHost: ${coordinatorHost}`);
    }
  }

  // Keep-awake: prevent system sleep while worker is running
  if (config.keepAwake && config.keepAwake.enabled) {
    const { startKeepAwake } = await import("../lib/keep-awake.js");
    keepAwakeHandle = startKeepAwake({ enabled: true });
    log("Sleep prevention is active");
  }

  connect();
}

start();
