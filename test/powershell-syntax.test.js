import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { execSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = resolve(fileURLToPath(import.meta.url), '..');
const projectRoot = resolve(__dirname, '..');

/**
 * Collect all .ps1 files in the given directories (non-recursive).
 */
function findPs1Files(...dirs) {
  const files = [];
  for (const dir of dirs) {
    const fullDir = join(projectRoot, dir);
    try {
      for (const f of readdirSync(fullDir)) {
        if (f.endsWith('.ps1')) {
          files.push(join(fullDir, f));
        }
      }
    } catch {
      // directory may not exist
    }
  }
  return files;
}

/**
 * Read file content for static analysis.
 */
function readPs1(filePath) {
  return readFileSync(filePath, 'utf-8');
}

const ps1Files = findPs1Files('install', 'installer', 'scripts');

// ============================================================
// 1. Syntax validation — PowerShell parser
// ============================================================
describe('PowerShell syntax validation', () => {
  for (const filePath of ps1Files) {
    const relPath = filePath.replace(projectRoot + '\\', '').replace(projectRoot + '/', '');

    it(`${relPath} should parse without syntax errors`, () => {
      const cmd = `powershell -NoProfile -Command "` +
        `$tokens = $null; $parseErrors = $null; ` +
        `[void][System.Management.Automation.Language.Parser]::ParseFile('${filePath.replace(/'/g, "''")}', [ref]$tokens, [ref]$parseErrors); ` +
        `if ($parseErrors.Count -gt 0) { foreach ($e in $parseErrors) { Write-Output \\"Line $($e.Extent.StartLineNumber): $($e.Message)\\" }; exit 1 } ` +
        `else { Write-Output 'OK'; exit 0 }"`;

      try {
        const result = execSync(cmd, { encoding: 'utf-8', timeout: 15000 });
        assert.ok(result.trim().includes('OK'), `Syntax errors in ${relPath}:\n${result}`);
      } catch (err) {
        assert.fail(`Syntax errors in ${relPath}:\n${err.stdout || err.message}`);
      }
    });
  }
});

// ============================================================
// 2. Static analysis — common PowerShell pitfalls
// ============================================================
describe('PowerShell static analysis', () => {
  for (const filePath of ps1Files) {
    const relPath = filePath.replace(projectRoot + '\\', '').replace(projectRoot + '/', '');
    const content = readPs1(filePath);
    const lines = content.split(/\r?\n/);

    // --- A. MessageBox leaking into pipeline ---
    // Any MessageBox::Show that isn't suppressed with [void] or assigned to a variable
    // will leak a DialogResult into the pipeline, corrupting function return values.
    it(`${relPath} should suppress MessageBox return values`, () => {
      const issues = [];
      lines.forEach((line, i) => {
        if (/\[System\.Windows\.Forms\.MessageBox\]::Show\(/.test(line)) {
          const trimmed = line.trim();
          // OK patterns: [void][System...], $var = [System...], | Out-Null
          if (!trimmed.startsWith('[void]') &&
              !trimmed.startsWith('$') &&
              !trimmed.includes('| Out-Null')) {
            issues.push(`  Line ${i + 1}: ${trimmed.substring(0, 80)}`);
          }
        }
      });
      assert.equal(issues.length, 0,
        `Unsuppressed MessageBox calls (will leak DialogResult to pipeline):\n${issues.join('\n')}`);
    });

    // --- B. Join-Path with 3+ arguments (PS 5.1 only supports 2) ---
    it(`${relPath} should not use Join-Path with 3+ arguments`, () => {
      const issues = [];
      lines.forEach((line, i) => {
        // Match Join-Path followed by 3+ string/variable args (not nested Join-Path)
        const match = line.match(/Join-Path\s+(?!\(Join-Path)\S+\s+"[^"]+"\s+"[^"]+"/);
        if (match) {
          issues.push(`  Line ${i + 1}: ${line.trim().substring(0, 80)}`);
        }
      });
      assert.equal(issues.length, 0,
        `Join-Path with 3+ args (PS 5.1 only supports 2):\n${issues.join('\n')}`);
    });

    // --- C. Here-string closing tag must be at column 0 ---
    it(`${relPath} should have here-string closing tags at column 0`, () => {
      const issues = [];
      lines.forEach((line, i) => {
        // "@ or '@ with leading whitespace = broken here-string
        if (/^\s+"@/.test(line) || /^\s+'@/.test(line)) {
          issues.push(`  Line ${i + 1}: ${line}`);
        }
      });
      assert.equal(issues.length, 0,
        `Indented here-string closing tags (must be at column 0):\n${issues.join('\n')}`);
    });

    // --- D. [char] overflow (> 0xFFFF) ---
    it(`${relPath} should not use [char] for values > 0xFFFF`, () => {
      const issues = [];
      lines.forEach((line, i) => {
        const matches = line.matchAll(/\[char\]\s*0x([0-9a-fA-F]+)/g);
        for (const m of matches) {
          const val = parseInt(m[1], 16);
          if (val > 0xFFFF) {
            issues.push(`  Line ${i + 1}: [char]0x${m[1]} (${val}) exceeds UInt16 max`);
          }
        }
      });
      assert.equal(issues.length, 0,
        `[char] overflow (use [System.Char]::ConvertFromUtf32 instead):\n${issues.join('\n')}`);
    });

    // --- E. Set-Content -Encoding UTF8 for JSON files (writes BOM) ---
    it(`${relPath} should not use Set-Content UTF8 for JSON/config files`, () => {
      const issues = [];
      lines.forEach((line, i) => {
        if (/Set-Content.*-Encoding\s+UTF8/i.test(line) &&
            /config|\.json/i.test(line)) {
          issues.push(`  Line ${i + 1}: ${line.trim().substring(0, 80)}`);
        }
      });
      assert.equal(issues.length, 0,
        `Set-Content -Encoding UTF8 writes BOM which breaks JSON.parse.\nUse [System.IO.File]::WriteAllText with UTF8Encoding($false):\n${issues.join('\n')}`);
    });

    // --- F. [void] combined with | Out-Null (crashes with "Argument type cannot be System.Void") ---
    it(`${relPath} should not combine [void] with | Out-Null`, () => {
      const issues = [];
      lines.forEach((line, i) => {
        if (/\[void\].*\|\s*Out-Null/.test(line)) {
          issues.push(`  Line ${i + 1}: ${line.trim().substring(0, 80)}`);
        }
      });
      assert.equal(issues.length, 0,
        `[void] + | Out-Null crashes PS ("Argument type cannot be System.Void"):\n${issues.join('\n')}`);
    });

    // --- G. return inside switch (exits switch, not function) ---
    it(`${relPath} should not use return inside switch for validation`, () => {
      const issues = [];
      let inSwitch = 0;
      let inFunction = null;
      lines.forEach((line, i) => {
        const trimmed = line.trim();
        if (/^function\s+Validate/i.test(trimmed)) {
          inFunction = i + 1;
        }
        if (inFunction && /^\s*switch\s*\(/.test(line)) {
          inSwitch++;
        }
        if (inFunction && inSwitch > 0 && /return\s+\$false/.test(trimmed)) {
          issues.push(`  Line ${i + 1}: return $false inside switch (exits switch, not function)`);
        }
        // Track brace depth roughly
        if (inSwitch > 0 && trimmed === '}') {
          // This is imprecise but catches obvious cases
        }
        // Reset on next function
        if (inFunction && /^function\s+/.test(trimmed) && i + 1 !== inFunction) {
          inFunction = null;
          inSwitch = 0;
        }
      });
      // Note: This is a heuristic check. It may have false positives for nested blocks.
      // The key pattern to catch is: function Validate-Step { switch { case { return $false } } }
      assert.equal(issues.length, 0,
        `return $false inside switch in Validate function (use if/elseif instead):\n${issues.join('\n')}`);
    });
  }
});

// ============================================================
// 3. JavaScript security checks
// ============================================================
describe('JavaScript security checks', () => {
  it('worker/agent-relay.js should not use shell: true in spawn', () => {
    const content = readFileSync(join(projectRoot, 'worker', 'agent-relay.js'), 'utf-8');
    const lines = content.split(/\r?\n/);
    const issues = [];
    lines.forEach((line, i) => {
      if (/shell\s*:\s*true/.test(line)) {
        issues.push(`  Line ${i + 1}: ${line.trim()}`);
      }
    });
    assert.equal(issues.length, 0,
      `shell: true enables command injection:\n${issues.join('\n')}`);
  });

  it('relay/config.json should not have default PIN "1234"', () => {
    const config = JSON.parse(readFileSync(join(projectRoot, 'relay', 'config.json'), 'utf-8'));
    assert.notEqual(config.pin?.code, '1234', 'Default PIN should not be "1234"');
  });

  it('relay/server.js cors() function should not use wildcard CORS', () => {
    const content = readFileSync(join(projectRoot, 'relay', 'server.js'), 'utf-8');
    // Extract the cors function body (between "function cors" and the next "}")
    const corsMatch = content.match(/function cors\([\s\S]*?\n\}/);
    assert.ok(corsMatch, 'cors() function should exist');
    assert.ok(!corsMatch[0].includes("'*'"),
      'cors() function should not use wildcard * for API endpoints');
  });

  it('dashboard should escape t.status in HTML', () => {
    const content = readFileSync(join(projectRoot, 'dashboard', 'index.html'), 'utf-8');
    // Check that status badge uses escapeHtml
    const statusBadgeLines = content.split('\n').filter(l => l.includes('status-badge'));
    for (const line of statusBadgeLines) {
      if (line.includes('t.status') && !line.includes('escapeHtml(t.status)')) {
        assert.fail(`Unescaped t.status in: ${line.trim()}`);
      }
    }
  });

  it('discovery broadcasts should be HMAC-signed', () => {
    const content = readFileSync(join(projectRoot, 'relay', 'discovery.js'), 'utf-8');
    assert.ok(content.includes('createHmac'), 'Discovery broadcast should use HMAC signing');
  });

  it('worker discovery should verify HMAC', () => {
    const content = readFileSync(join(projectRoot, 'worker', 'discovery.js'), 'utf-8');
    assert.ok(content.includes('timingSafeEqual'), 'Worker discovery should verify HMAC with timing-safe comparison');
  });

  it('agent wizard Test Connection should require shared secret', () => {
    const content = readFileSync(join(projectRoot, 'installer', 'agent-setup-wizard.ps1'), 'utf-8');
    assert.ok(content.includes('enter the shared secret first') || content.includes('Please enter the shared secret'),
      'Test Connection should check for empty secret before testing');
  });

  it('agent wizard Test Connection should verify HMAC on UDP discovery', () => {
    const content = readFileSync(join(projectRoot, 'installer', 'agent-setup-wizard.ps1'), 'utf-8');
    assert.ok(content.includes('HMACSHA256'),
      'Auto-discovery test should verify HMAC signature');
    assert.ok(content.includes('HMAC mismatch'),
      'Auto-discovery test should report HMAC mismatch on wrong secret');
  });

  it('agent wizard should write config without UTF-8 BOM', () => {
    const content = readFileSync(join(projectRoot, 'installer', 'agent-setup-wizard.ps1'), 'utf-8');
    assert.ok(content.includes('UTF8Encoding $false'),
      'Config should be written with UTF8Encoding($false) to avoid BOM');
  });

  it('orchestrator wizard should pass auth token to dashboard URL', () => {
    const content = readFileSync(join(projectRoot, 'install', 'setup-wizard.ps1'), 'utf-8');
    assert.ok(content.includes('token=$encodedSecret'),
      'Dashboard URL should include token parameter for auto-auth');
  });

  it('dashboard should auto-import token from URL parameter', () => {
    const content = readFileSync(join(projectRoot, 'dashboard', 'index.html'), 'utf-8');
    assert.ok(content.includes("urlParams.get('token')"),
      'Dashboard should read token from URL parameter');
    assert.ok(content.includes('replaceState'),
      'Dashboard should strip token from URL after importing');
  });
});
