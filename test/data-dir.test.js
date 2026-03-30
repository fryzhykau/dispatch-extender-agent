/**
 * test/data-dir.test.js
 *
 * Tests for lib/data-dir.js — writable data directory resolution.
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { getDataDir } from '../lib/data-dir.js';

let tmpDir;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'datadir-test-'));
});

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe('getDataDir', () => {
  it('should return a path ending in "data"', () => {
    const result = getDataDir(tmpDir);
    assert.ok(result.endsWith('data'));
  });

  it('should create the data directory if it does not exist', () => {
    const base = path.join(tmpDir, 'project');
    fs.mkdirSync(base);
    const result = getDataDir(base);
    assert.ok(fs.existsSync(result));
  });

  it('should resolve relative to fallbackBase in normal directories', () => {
    const result = getDataDir(tmpDir);
    const expected = path.resolve(tmpDir, 'data');
    assert.equal(result, expected);
  });

  it('should return APPDATA-based path for Program Files locations', () => {
    // Only test if APPDATA is set (it always is on Windows)
    if (!process.env.APPDATA) return;

    // Simulate a Program Files path
    const result = getDataDir('C:\\Program Files\\DispatchOrchestrator');
    assert.ok(result.includes('DispatchOrchestrator'),
      'Should include app name in APPDATA path');
    assert.ok(!result.includes('Program Files'),
      'Should NOT be inside Program Files');
  });

  it('should be idempotent — calling twice returns same path', () => {
    const result1 = getDataDir(tmpDir);
    const result2 = getDataDir(tmpDir);
    assert.equal(result1, result2);
  });
});
