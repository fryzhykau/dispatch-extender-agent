/**
 * test/keep-awake.test.js
 *
 * Tests for lib/keep-awake.js — sleep prevention.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { startKeepAwake } from '../lib/keep-awake.js';

describe('startKeepAwake', () => {
  it('should return an object with a stop method', () => {
    const handle = startKeepAwake({ enabled: false });
    assert.equal(typeof handle.stop, 'function');
  });

  it('should be a no-op when disabled', () => {
    const handle = startKeepAwake({ enabled: false });
    // Should not throw
    handle.stop();
  });

  it('should default to enabled when no options provided', () => {
    // On Windows this spawns PowerShell; on other platforms it's a no-op
    const handle = startKeepAwake();
    assert.equal(typeof handle.stop, 'function');
    handle.stop();
  });

  it('should handle stop() being called multiple times', () => {
    const handle = startKeepAwake({ enabled: false });
    handle.stop();
    handle.stop(); // Should not throw
  });
});

describe('keep-awake PowerShell script', () => {
  it('should use [uint32] cast for SetThreadExecutionState flags', async () => {
    // Verify the fix for the UInt32 overflow bug:
    // 0x80000001 overflows PowerShell's signed int → UInt32 conversion
    // The fix is to use [uint32]0x80000001 explicitly
    const { readFileSync } = await import('node:fs');
    const { dirname, join } = await import('node:path');
    const { fileURLToPath } = await import('node:url');

    const __dirname = dirname(fileURLToPath(import.meta.url));
    const source = readFileSync(join(__dirname, '..', 'lib', 'keep-awake.js'), 'utf-8');

    // The main loop should use decimal to avoid PowerShell signed hex overflow
    assert.ok(source.includes('[uint32]2147483649'),
      'PS_SCRIPT should use decimal 2147483649 for ES_CONTINUOUS | ES_SYSTEM_REQUIRED');

    // The clear script should also use decimal
    assert.ok(source.includes('[uint32]2147483648'),
      'PS_CLEAR_SCRIPT should use decimal 2147483648 for ES_CONTINUOUS');
  });
});
