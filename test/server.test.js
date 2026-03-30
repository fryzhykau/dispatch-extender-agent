/**
 * Integration tests for the relay server HTTP API and WebSocket.
 *
 * Spawns the server as a child process on a test port (7099) with a
 * temporary config, runs all tests, then tears everything down.
 */

import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ---------------------------------------------------------------------------
// Test configuration
// ---------------------------------------------------------------------------

const TEST_PORT = 7099;
const BASE_URL = `http://127.0.0.1:${TEST_PORT}`;
const WS_URL = `ws://127.0.0.1:${TEST_PORT}`;

// Read the real config to get the shared secret (and base structure)
const realConfigPath = path.resolve(__dirname, '..', 'relay', 'config.json');
const realConfig = JSON.parse(fs.readFileSync(realConfigPath, 'utf-8'));
const SHARED_SECRET = realConfig.sharedSecret;

// Build a test-specific config with a different port, low rate limits,
// discovery/keepAwake disabled, and PIN enabled for testing.
const testConfig = {
  ...realConfig,
  port: TEST_PORT,
  discovery: { enabled: false },
  keepAwake: { enabled: false },
  tls: { enabled: false },
  rateLimiting: {
    enabled: true,
    maxTasksPerMinute: 20,
    maxTasksPerHour: 200,
  },
  pin: {
    enabled: true,
    code: '9999',
    maxAttempts: 5,
    lockoutMinutes: 15,
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Standard auth header for authenticated requests. */
const authHeaders = {
  Authorization: `Bearer ${SHARED_SECRET}`,
  'Content-Type': 'application/json',
};

/**
 * Wait for a WebSocket to reach the given readyState (or timeout).
 * @param {WebSocket} ws
 * @param {number} state - e.g. WebSocket.OPEN
 * @param {number} [timeoutMs=5000]
 */
function waitForState(ws, state, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    if (ws.readyState === state) return resolve();
    const timer = setTimeout(() => reject(new Error(`WS did not reach state ${state} within ${timeoutMs}ms`)), timeoutMs);
    ws.on(state === WebSocket.OPEN ? 'open' : 'close', () => {
      clearTimeout(timer);
      resolve();
    });
    ws.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

/**
 * Open a WebSocket and wait for it to connect.
 */
function openWs() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(WS_URL);
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

/**
 * Wait for the next message on a WebSocket.
 */
function nextMessage(ws, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Timed out waiting for WS message')), timeoutMs);
    ws.once('message', (data) => {
      clearTimeout(timer);
      resolve(JSON.parse(data.toString()));
    });
  });
}

/**
 * Wait for the WebSocket 'close' event.
 */
function waitForClose(ws, timeoutMs = 5000) {
  return new Promise((resolve, reject) => {
    if (ws.readyState === WebSocket.CLOSED) return resolve();
    const timer = setTimeout(() => reject(new Error('Timed out waiting for WS close')), timeoutMs);
    ws.on('close', (code, reason) => {
      clearTimeout(timer);
      resolve({ code, reason: reason.toString() });
    });
  });
}

// ---------------------------------------------------------------------------
// Server lifecycle
// ---------------------------------------------------------------------------

let serverProcess;

/**
 * Write a temporary test config, spawn the server, wait for the "Ready" log.
 */
async function startServer() {
  // Write test config over the real one (we restore it later)
  const testConfigPath = path.resolve(__dirname, '..', 'relay', 'config.test.json');
  fs.writeFileSync(testConfigPath, JSON.stringify(testConfig, null, 2));

  // We cannot easily make server.js read a different config path, so we
  // temporarily swap the config file content. Keep a backup.
  const backupConfigPath = realConfigPath + '.bak';
  fs.copyFileSync(realConfigPath, backupConfigPath);
  fs.writeFileSync(realConfigPath, JSON.stringify(testConfig, null, 2));

  return new Promise((resolve, reject) => {
    const serverEntry = path.resolve(__dirname, '..', 'relay', 'server.js');
    serverProcess = spawn(process.execPath, [serverEntry], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env },
    });

    let started = false;
    const timeoutId = setTimeout(() => {
      if (!started) {
        reject(new Error('Server did not start within 15 seconds'));
      }
    }, 15000);

    serverProcess.stdout.on('data', (chunk) => {
      const text = chunk.toString();
      if (!started && text.includes('Ready')) {
        started = true;
        clearTimeout(timeoutId);
        resolve();
      }
    });

    serverProcess.stderr.on('data', (chunk) => {
      // Relay stderr for debugging — but don't fail on it
      process.stderr.write(`[server stderr] ${chunk}`);
    });

    serverProcess.on('error', (err) => {
      clearTimeout(timeoutId);
      reject(err);
    });

    serverProcess.on('exit', (code) => {
      if (!started) {
        clearTimeout(timeoutId);
        reject(new Error(`Server exited prematurely with code ${code}`));
      }
    });
  });
}

function stopServer() {
  // Restore original config
  const backupConfigPath = realConfigPath + '.bak';
  if (fs.existsSync(backupConfigPath)) {
    fs.copyFileSync(backupConfigPath, realConfigPath);
    fs.unlinkSync(backupConfigPath);
  }
  // Remove test config artifact
  const testConfigPath = path.resolve(__dirname, '..', 'relay', 'config.test.json');
  if (fs.existsSync(testConfigPath)) fs.unlinkSync(testConfigPath);

  return new Promise((resolve) => {
    if (!serverProcess || serverProcess.exitCode !== null) {
      resolve();
      return;
    }
    serverProcess.on('exit', () => resolve());
    serverProcess.kill('SIGTERM');
    // Force-kill fallback
    setTimeout(() => {
      try { serverProcess.kill('SIGKILL'); } catch { /* ignore */ }
      resolve();
    }, 5000);
  });
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

describe('Relay server integration tests', () => {
  before(async () => {
    await startServer();
  });

  after(async () => {
    await stopServer();
  });

  // =========================================================================
  // HTTP API Authentication
  // =========================================================================

  describe('HTTP API Authentication', () => {
    it('GET /status without auth header should return 401', async () => {
      const res = await fetch(`${BASE_URL}/status`);
      assert.equal(res.status, 401);
      const body = await res.json();
      assert.equal(body.error, 'Unauthorized');
    });

    it('GET /status with wrong token should return 401', async () => {
      const res = await fetch(`${BASE_URL}/status`, {
        headers: { Authorization: 'Bearer wrong-token' },
      });
      assert.equal(res.status, 401);
    });

    it('GET /status with correct Bearer token should return 200', async () => {
      const res = await fetch(`${BASE_URL}/status`, {
        headers: { Authorization: `Bearer ${SHARED_SECRET}` },
      });
      assert.equal(res.status, 200);
    });
  });

  // =========================================================================
  // GET /status
  // =========================================================================

  describe('GET /status', () => {
    it('should return an array (empty when no workers connected)', async () => {
      const res = await fetch(`${BASE_URL}/status`, { headers: authHeaders });
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.ok(Array.isArray(body), 'Expected an array');
      assert.equal(body.length, 0, 'Expected no connected workers');
    });
  });

  // =========================================================================
  // POST /task validation
  // =========================================================================

  describe('POST /task validation', () => {
    it('should return 400 when machineId is missing', async () => {
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ prompt: 'hello', pin: '9999' }),
      });
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.ok(body.error.toLowerCase().includes('machineid'), `Expected machineId error, got: ${body.error}`);
    });

    it('should return 400 when prompt is missing', async () => {
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-machine', pin: '9999' }),
      });
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.ok(body.error.toLowerCase().includes('prompt') || body.error.toLowerCase().includes('required'),
        `Expected prompt-related error, got: ${body.error}`);
    });

    it('should return 400 when prompt exceeds max length', async () => {
      const longPrompt = 'x'.repeat(50001);
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-machine', prompt: longPrompt, pin: '9999' }),
      });
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.ok(body.error.includes('maximum length') || body.error.includes('exceeds'),
        `Expected max length error, got: ${body.error}`);
    });

    it('should return 400 when targeting a non-existent machine (no workers connected)', async () => {
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'nonexistent-machine', prompt: 'hello', pin: '9999' }),
      });
      // Server returns 400 "Machine X is not connected" when queue is enabled it returns 202
      // With queue enabled it queues the task; either 202 or 400 is acceptable
      assert.ok([400, 202].includes(res.status),
        `Expected 400 or 202, got ${res.status}`);
    });

    it('should return 403 when PIN is wrong', async () => {
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-machine', prompt: 'hello', pin: 'wrong-pin' }),
      });
      assert.equal(res.status, 403);
      const body = await res.json();
      assert.ok(body.error.includes('PIN') || body.error.includes('Invalid'),
        `Expected PIN error, got: ${body.error}`);
    });

    it('should return 403 when PIN is missing', async () => {
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-machine', prompt: 'hello' }),
      });
      assert.equal(res.status, 403);
    });
  });

  // =========================================================================
  // GET /task/:id
  // =========================================================================

  describe('GET /task/:id', () => {
    it('should return 404 for non-existent task', async () => {
      const res = await fetch(`${BASE_URL}/task/does-not-exist-id`, {
        headers: authHeaders,
      });
      assert.equal(res.status, 404);
      const body = await res.json();
      assert.equal(body.error, 'Task not found');
    });
  });

  // =========================================================================
  // GET /tasks
  // =========================================================================

  describe('GET /tasks', () => {
    it('should return tasks list with total count', async () => {
      const res = await fetch(`${BASE_URL}/tasks`, { headers: authHeaders });
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.ok(Array.isArray(body.tasks), 'Expected tasks to be an array');
      assert.equal(typeof body.total, 'number', 'Expected total to be a number');
    });
  });

  // =========================================================================
  // GET /dashboard
  // =========================================================================

  describe('GET /dashboard', () => {
    it('should return 200 with HTML content (no auth required)', async () => {
      const res = await fetch(`${BASE_URL}/dashboard`);
      assert.equal(res.status, 200);
      const contentType = res.headers.get('content-type');
      assert.ok(contentType.includes('text/html'), `Expected text/html, got: ${contentType}`);
      const text = await res.text();
      assert.ok(text.length > 0, 'Expected non-empty HTML body');
      assert.ok(text.includes('<'), 'Expected HTML content');
    });
  });

  // =========================================================================
  // WebSocket Authentication
  // =========================================================================

  describe('WebSocket Authentication', () => {
    it('should disconnect when register message has wrong token', async () => {
      const ws = await openWs();
      const closePromise = waitForClose(ws);

      ws.send(JSON.stringify({
        type: 'register',
        machineId: 'test-ws-bad',
        token: 'wrong-secret',
      }));

      const { code } = await closePromise;
      assert.equal(code, 4003, `Expected close code 4003, got ${code}`);
    });

    it('should accept connection with correct token', async () => {
      const ws = await openWs();

      ws.send(JSON.stringify({
        type: 'register',
        machineId: 'test-ws-good',
        token: SHARED_SECRET,
        agentName: 'TestAgent',
      }));

      // If registration is accepted, the server does NOT close the connection.
      // Wait briefly then verify it is still open.
      await new Promise((r) => setTimeout(r, 500));
      assert.equal(ws.readyState, WebSocket.OPEN, 'Expected WebSocket to remain open after valid registration');

      // Verify the worker appears in /status
      const res = await fetch(`${BASE_URL}/status`, { headers: authHeaders });
      const body = await res.json();
      const worker = body.find((w) => w.machineId === 'test-ws-good');
      assert.ok(worker, 'Expected test-ws-good to appear in /status');
      assert.equal(worker.status, 'idle');
      assert.equal(worker.agentName, 'TestAgent');

      ws.close();
      // Wait for cleanup
      await new Promise((r) => setTimeout(r, 300));
    });
  });

  // =========================================================================
  // Path Validation (via POST /task with workingDir)
  // =========================================================================

  describe('Path Validation', () => {
    it('should reject workingDir with ".." traversal', async () => {
      // First we need to pass PIN and have a valid machineId structure
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({
          machineId: 'some-machine',
          prompt: 'test traversal',
          workingDir: '/home/user/../../../etc/passwd',
          pin: '9999',
        }),
      });
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.ok(body.error.includes('..') || body.error.includes('traversal'),
        `Expected traversal error, got: ${body.error}`);
    });

    it('should reject workingDir with null bytes', async () => {
      const res = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({
          machineId: 'some-machine',
          prompt: 'test null byte',
          workingDir: '/home/user/\0evil',
          pin: '9999',
        }),
      });
      assert.equal(res.status, 400);
      const body = await res.json();
      assert.ok(body.error.includes('null') || body.error.includes('Invalid'),
        `Expected null byte error, got: ${body.error}`);
    });
  });

  // =========================================================================
  // Rate Limiting
  // =========================================================================

  describe('Rate Limiting', () => {
    it('should return 429 after exceeding maxTasksPerMinute', async () => {
      // Test config has maxTasksPerMinute = 20.
      // Previous tests already consumed some tokens.  Send enough requests
      // (25) to guarantee we exceed the per-minute window.
      const results = [];

      for (let i = 0; i < 25; i++) {
        const res = await fetch(`${BASE_URL}/task`, {
          method: 'POST',
          headers: authHeaders,
          body: JSON.stringify({
            machineId: 'rate-limit-machine',
            prompt: `rate limit test ${i}`,
            pin: '9999',
          }),
        });
        results.push(res.status);
      }

      // At least one should be 429
      assert.ok(
        results.includes(429),
        `Expected at least one 429 response, got statuses: ${results.join(', ')}`
      );

      // The 429 response should include Retry-After header
      const lastRes = await fetch(`${BASE_URL}/task`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({
          machineId: 'rate-limit-machine',
          prompt: 'one more',
          pin: '9999',
        }),
      });
      if (lastRes.status === 429) {
        const retryAfter = lastRes.headers.get('retry-after');
        assert.ok(retryAfter, 'Expected Retry-After header on 429 response');
      }
    });
  });
});
