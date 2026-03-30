/**
 * test/audit.test.js
 *
 * Tests for the audit logging module (relay/audit.js).
 */

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { initAudit } from '../relay/audit.js';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

let tmpDir;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'audit-test-'));
});

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('initAudit', () => {
  it('should create the log directory if it does not exist', () => {
    const logDir = path.join(tmpDir, 'nested', 'logs');
    initAudit(logDir);
    assert.ok(fs.existsSync(logDir));
  });

  it('should return an object with log, warn, error, security, and getLogPath', () => {
    const audit = initAudit(tmpDir);
    assert.equal(typeof audit.log, 'function');
    assert.equal(typeof audit.warn, 'function');
    assert.equal(typeof audit.error, 'function');
    assert.equal(typeof audit.security, 'function');
    assert.equal(typeof audit.getLogPath, 'function');
  });

  it('getLogPath should return a path ending in audit.log', () => {
    const audit = initAudit(tmpDir);
    assert.ok(audit.getLogPath().endsWith('audit.log'));
  });
});

describe('audit.log', () => {
  it('should write a JSON line with level "info"', () => {
    const audit = initAudit(tmpDir);
    audit.log('task.submitted', { machineId: 'machine-1' });

    const content = fs.readFileSync(audit.getLogPath(), 'utf-8').trim();
    const entry = JSON.parse(content);

    assert.equal(entry.level, 'info');
    assert.equal(entry.event, 'task.submitted');
    assert.equal(entry.details.machineId, 'machine-1');
    assert.ok(entry.timestamp);
  });
});

describe('audit.warn', () => {
  it('should write a JSON line with level "warn"', () => {
    const audit = initAudit(tmpDir);
    audit.warn('worker.disconnected', { machineId: 'machine-2' });

    const content = fs.readFileSync(audit.getLogPath(), 'utf-8').trim();
    const entry = JSON.parse(content);

    assert.equal(entry.level, 'warn');
    assert.equal(entry.event, 'worker.disconnected');
  });
});

describe('audit.error', () => {
  it('should write a JSON line with level "error"', () => {
    const audit = initAudit(tmpDir);
    audit.error('task.error', { taskId: 't1', error: 'timeout' });

    const content = fs.readFileSync(audit.getLogPath(), 'utf-8').trim();
    const entry = JSON.parse(content);

    assert.equal(entry.level, 'error');
    assert.equal(entry.event, 'task.error');
  });
});

describe('audit.security', () => {
  it('should write with level "error" and prefix event with "SECURITY: "', () => {
    const audit = initAudit(tmpDir);
    audit.security('auth.failed', { ip: '192.168.1.1', reason: 'wrong token' });

    const content = fs.readFileSync(audit.getLogPath(), 'utf-8').trim();
    const entry = JSON.parse(content);

    assert.equal(entry.level, 'error');
    assert.equal(entry.event, 'SECURITY: auth.failed');
    assert.equal(entry.details.reason, 'wrong token');
  });
});

describe('multiple entries', () => {
  it('should append entries as separate lines (JSONL format)', () => {
    const audit = initAudit(tmpDir);
    audit.log('event.one', { a: 1 });
    audit.log('event.two', { b: 2 });
    audit.warn('event.three', { c: 3 });

    const lines = fs.readFileSync(audit.getLogPath(), 'utf-8')
      .split('\n')
      .filter((l) => l.trim().length > 0);

    assert.equal(lines.length, 3);

    const entry1 = JSON.parse(lines[0]);
    const entry2 = JSON.parse(lines[1]);
    const entry3 = JSON.parse(lines[2]);

    assert.equal(entry1.event, 'event.one');
    assert.equal(entry2.event, 'event.two');
    assert.equal(entry3.level, 'warn');
  });
});

describe('empty details', () => {
  it('should default details to empty object when not provided', () => {
    const audit = initAudit(tmpDir);
    audit.log('no.details');

    const content = fs.readFileSync(audit.getLogPath(), 'utf-8').trim();
    const entry = JSON.parse(content);

    assert.deepEqual(entry.details, {});
  });
});
