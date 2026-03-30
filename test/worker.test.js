/**
 * test/worker.test.js
 *
 * Tests for worker path validation logic (isPathAllowed / normalizePath).
 *
 * Since agent-relay.js auto-executes on import, we extract the pure functions
 * here as local helpers for isolated testing.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';

// ---------------------------------------------------------------------------
// Extracted from worker/agent-relay.js (pure functions, no side effects)
// ---------------------------------------------------------------------------

function normalizePath(p) {
  let resolved = path.resolve(p);
  resolved = resolved.replace(/\\/g, '/');
  resolved = resolved.replace(/\/+$/, '') || resolved;
  return resolved;
}

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
// Test data
// ---------------------------------------------------------------------------

const ALLOWED_DIRS = ['C:/workspace', 'C:/projects'];
const DENY_DIRS = [
  'C:/Windows',
  'C:/Program Files',
  'C:/Program Files (x86)',
  'C:/Users/*/AppData',
];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('isPathAllowed', () => {

  it('should allow paths within allowedDirs', () => {
    const result = isPathAllowed('C:/workspace/my-project/src', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, true);
  });

  it('should deny paths in denyDirs', () => {
    const result = isPathAllowed('C:/Windows/System32', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, false);
    assert.match(result.reason, /denied directory/i);
  });

  it('should deny C:/Windows', () => {
    const result = isPathAllowed('C:/Windows', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, false);
  });

  it('should deny C:/Program Files', () => {
    const result = isPathAllowed('C:/Program Files', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, false);
  });

  it('should deny paths with .. traversal', () => {
    // Attempt to escape from an allowed dir into a denied one
    const result = isPathAllowed('C:/workspace/../Windows/System32', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, false);
  });

  it('should handle backslash/forward slash normalization', () => {
    const resultFwd = isPathAllowed('C:/workspace/project', ALLOWED_DIRS, DENY_DIRS);
    const resultBack = isPathAllowed('C:\\workspace\\project', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(resultFwd.allowed, true);
    assert.equal(resultBack.allowed, true);

    const resultDenyFwd = isPathAllowed('C:/Windows/temp', ALLOWED_DIRS, DENY_DIRS);
    const resultDenyBack = isPathAllowed('C:\\Windows\\temp', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(resultDenyFwd.allowed, false);
    assert.equal(resultDenyBack.allowed, false);
  });

  it('should handle glob patterns in denyDirs (e.g. C:/Users/*/AppData)', () => {
    const result = isPathAllowed('C:/Users/john/AppData/Local', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, false);
    assert.match(result.reason, /denied directory/i);

    const result2 = isPathAllowed('C:/Users/admin/AppData', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result2.allowed, false);
  });

  it('should deny paths not in any allowedDir', () => {
    const result = isPathAllowed('C:/some-random-dir/stuff', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, false);
    assert.match(result.reason, /not under any allowed directory/i);
  });

  it('should allow exact match of allowedDir', () => {
    const result = isPathAllowed('C:/workspace', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, true);
  });

  it('should allow subdirectories of allowedDir', () => {
    const result = isPathAllowed('C:/workspace/deep/nested/dir', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result.allowed, true);

    const result2 = isPathAllowed('C:/projects/foo/bar', ALLOWED_DIRS, DENY_DIRS);
    assert.equal(result2.allowed, true);
  });
});

describe('normalizePath', () => {

  it('should convert backslashes to forward slashes', () => {
    const result = normalizePath('C:\\Users\\test\\project');
    assert.ok(!result.includes('\\'), 'Expected no backslashes in normalized path');
    assert.ok(result.includes('/'), 'Expected forward slashes in normalized path');
  });

  it('should resolve .. segments', () => {
    const result = normalizePath('C:/workspace/foo/../bar');
    assert.equal(result, 'C:/workspace/bar');
  });

  it('should strip trailing slashes', () => {
    const result = normalizePath('C:/workspace/');
    assert.ok(!result.endsWith('/') || result === 'C:/', 'Trailing slash should be stripped unless drive root');
  });
});
