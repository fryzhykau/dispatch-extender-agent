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
const ADMIN_SECRET = realConfig.adminSecret || realConfig.sharedSecret;
const WORKER_SECRET = realConfig.sharedSecret;  // legacy worker auth token

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
  Authorization: `Bearer ${ADMIN_SECRET}`,
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
        headers: { Authorization: `Bearer ${ADMIN_SECRET}` },
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
  // GET /favicon.ico
  // =========================================================================

  describe('GET /favicon.ico', () => {
    it('should return 204 with no body (no auth required)', async () => {
      const res = await fetch(`${BASE_URL}/favicon.ico`);
      assert.equal(res.status, 204);
      const body = await res.text();
      assert.equal(body, '', 'Expected empty body for 204 response');
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
        token: WORKER_SECRET,
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
  // WebSocket Security
  // =========================================================================

  describe('WebSocket Security', () => {
    it('should close stale connection when same machineId re-registers', async () => {
      const ws1 = await openWs();
      ws1.send(JSON.stringify({
        type: 'register',
        machineId: 'test-dup-machine',
        token: WORKER_SECRET,
      }));
      await new Promise((r) => setTimeout(r, 500));
      assert.equal(ws1.readyState, WebSocket.OPEN);

      // Second connection with same machineId
      const ws2 = await openWs();
      const close1 = waitForClose(ws1);
      ws2.send(JSON.stringify({
        type: 'register',
        machineId: 'test-dup-machine',
        token: WORKER_SECRET,
      }));

      const { code } = await close1;
      assert.equal(code, 4005, 'First connection should be closed with 4005');
      assert.equal(ws2.readyState, WebSocket.OPEN, 'Second connection should remain open');

      ws2.close();
      await new Promise((r) => setTimeout(r, 300));
    });

    it('should validate agentCapabilities is a string array', async () => {
      const ws = await openWs();
      ws.send(JSON.stringify({
        type: 'register',
        machineId: 'test-bad-caps',
        token: WORKER_SECRET,
        agentCapabilities: { __proto__: { polluted: true } },
      }));
      await new Promise((r) => setTimeout(r, 500));

      const res = await fetch(`${BASE_URL}/status`, { headers: authHeaders });
      const body = await res.json();
      const worker = body.find((w) => w.machineId === 'test-bad-caps');
      assert.ok(worker, 'Worker should still register');
      assert.ok(Array.isArray(worker.agentCapabilities), 'Capabilities should be an array');
      assert.equal(worker.agentCapabilities.length, 0, 'Invalid capabilities should be rejected');

      ws.close();
      await new Promise((r) => setTimeout(r, 300));
    });

    it('should validate agentName is a string', async () => {
      const ws = await openWs();
      ws.send(JSON.stringify({
        type: 'register',
        machineId: 'test-bad-name',
        token: WORKER_SECRET,
        agentName: 12345,
      }));
      await new Promise((r) => setTimeout(r, 500));

      const res = await fetch(`${BASE_URL}/status`, { headers: authHeaders });
      const body = await res.json();
      const worker = body.find((w) => w.machineId === 'test-bad-name');
      assert.ok(worker);
      assert.equal(worker.agentName, null, 'Non-string agentName should be rejected');

      ws.close();
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
  // Admin Endpoints (machine enrollment)
  // =========================================================================

  describe('Admin Endpoints', () => {
    // Clean up any test machines left from previous runs
    before(async () => {
      const res = await fetch(`${BASE_URL}/admin/machines`, { headers: authHeaders });
      if (res.ok) {
        const machines = await res.json();
        for (const m of machines) {
          if (m.machineId.startsWith('test-')) {
            await fetch(`${BASE_URL}/admin/revoke`, {
              method: 'POST', headers: authHeaders,
              body: JSON.stringify({ machineId: m.machineId }),
            });
          }
        }
      }
    });

    it('POST /admin/enroll should create a machine and return apiKey', async () => {
      const res = await fetch(`${BASE_URL}/admin/enroll`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-enroll-1', agentName: 'EnrollBot' }),
      });
      assert.equal(res.status, 201);
      const body = await res.json();
      assert.equal(body.machineId, 'test-enroll-1');
      assert.equal(body.agentName, 'EnrollBot');
      assert.equal(body.apiKey.length, 64, 'apiKey should be 64-char hex');
    });

    it('POST /admin/enroll should return 409 for duplicate machineId', async () => {
      await fetch(`${BASE_URL}/admin/enroll`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-dup-enroll' }),
      });
      const res = await fetch(`${BASE_URL}/admin/enroll`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-dup-enroll' }),
      });
      assert.equal(res.status, 409);
    });

    it('GET /admin/machines should list enrolled machines', async () => {
      const res = await fetch(`${BASE_URL}/admin/machines`, { headers: authHeaders });
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.ok(Array.isArray(body));
      const enrolled = body.find(m => m.machineId === 'test-enroll-1');
      assert.ok(enrolled, 'Previously enrolled machine should appear');
    });

    it('POST /admin/revoke should revoke a machine', async () => {
      const enrollRes = await fetch(`${BASE_URL}/admin/enroll`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-revoke-1' }),
      });
      assert.equal(enrollRes.status, 201);

      const res = await fetch(`${BASE_URL}/admin/revoke`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-revoke-1' }),
      });
      assert.equal(res.status, 200);
      const body = await res.json();
      assert.equal(body.revoked, 1);
    });

    it('WebSocket should accept per-machine apiKey', async () => {
      const enrollRes = await fetch(`${BASE_URL}/admin/enroll`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-apikey-ws', agentName: 'ApiKeyBot' }),
      });
      const { apiKey } = await enrollRes.json();

      const ws = await openWs();
      ws.send(JSON.stringify({
        type: 'register',
        machineId: 'test-apikey-ws',
        token: apiKey,
      }));
      await new Promise((r) => setTimeout(r, 500));
      assert.equal(ws.readyState, WebSocket.OPEN, 'Should remain connected with valid apiKey');

      const statusRes = await fetch(`${BASE_URL}/status`, { headers: authHeaders });
      const agents = await statusRes.json();
      const agent = agents.find(a => a.machineId === 'test-apikey-ws');
      assert.ok(agent, 'Agent should appear in status');
      assert.equal(agent.agentName, 'ApiKeyBot');

      ws.close();
      await new Promise((r) => setTimeout(r, 300));
    });

    it('WebSocket should reject revoked apiKey', async () => {
      const enrollRes = await fetch(`${BASE_URL}/admin/enroll`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-revoked-ws' }),
      });
      const { apiKey } = await enrollRes.json();

      await fetch(`${BASE_URL}/admin/revoke`, {
        method: 'POST',
        headers: authHeaders,
        body: JSON.stringify({ machineId: 'test-revoked-ws' }),
      });

      const ws = await openWs();
      const closePromise = waitForClose(ws);
      ws.send(JSON.stringify({
        type: 'register',
        machineId: 'test-revoked-ws',
        token: apiKey,
      }));

      const { code } = await closePromise;
      assert.equal(code, 4003, 'Should close with 4003 for revoked key');
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
