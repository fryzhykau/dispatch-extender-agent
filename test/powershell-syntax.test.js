import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { execSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = resolve(fileURLToPath(import.meta.url), '..');
const projectRoot = resolve(__dirname, '..');

/**
 * Collect all .ps1 files in the given directories (non-recursive for targeted scanning).
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

describe('PowerShell script syntax validation', () => {
  const ps1Files = findPs1Files('install', 'installer', 'scripts');

  for (const filePath of ps1Files) {
    const relPath = filePath.replace(projectRoot + '\\', '').replace(projectRoot + '/', '');

    it(`${relPath} should parse without syntax errors`, () => {
      // Use PowerShell's parser to check for syntax errors without executing
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
