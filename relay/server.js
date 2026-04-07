import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { initRegistry } from './registry.js';
import { initAudit } from './audit.js';
import { createTaskQueue } from './queue.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const config = JSON.parse(
  fs.readFileSync(path.resolve(__dirname, 'config.json'), 'utf-8')
);

const PORT = config.port ?? 7070;
const SHARED_SECRET = config.sharedSecret;
const ADMIN_SECRET = config.adminSecret || config.sharedSecret;
const LEGACY_AUTH_ENABLED = config.legacyAuthEnabled !== false;
const HEARTBEAT_INTERVAL = config.heartbeat?.intervalMs ?? 30000;
const HEARTBEAT_TIMEOUT = config.heartbeat?.timeoutMs ?? 10000;

// PIN-based hijack protection
const pinConfig = config.pin || { enabled: false };
/** @type {Map<string, { failures: number, lockedUntil: number|null }>} */
const pinLockouts = new Map();

// Rate limiting & size limit settings
const rateLimitConfig = config.rateLimiting || { enabled: false };
const limitsConfig = config.limits || {};
const MAX_PROMPT_LENGTH = limitsConfig.maxPromptLength ?? 50000;
const MAX_OUTPUT_LENGTH = limitsConfig.maxOutputLength ?? 1000000;
const MAX_REQUEST_BODY_BYTES = limitsConfig.maxRequestBodyBytes ?? 102400;

// ---------------------------------------------------------------------------
// Rate Limiter (in-memory sliding window)
// ---------------------------------------------------------------------------

class RateLimiter {
  constructor({ maxPerMinute, maxPerHour }) {
    this.maxPerMinute = maxPerMinute;
    this.maxPerHour = maxPerHour;
    this.timestamps = [];
  }

  /** Prune entries older than 1 hour */
  _prune() {
    const oneHourAgo = Date.now() - 60 * 60 * 1000;
    while (this.timestamps.length > 0 && this.timestamps[0] <= oneHourAgo) {
      this.timestamps.shift();
    }
  }

  /**
   * Check whether a new request is allowed.
   * @returns {{ allowed: boolean, retryAfterSeconds?: number }}
   */
  check() {
    this._prune();
    const now = Date.now();

    // Check per-minute limit
    const oneMinuteAgo = now - 60 * 1000;
    const countLastMinute = this.timestamps.filter((t) => t > oneMinuteAgo).length;
    if (countLastMinute >= this.maxPerMinute) {
      const oldestInWindow = this.timestamps.find((t) => t > oneMinuteAgo);
      const retryAfterSeconds = Math.ceil((oldestInWindow + 60 * 1000 - now) / 1000);
      return { allowed: false, retryAfterSeconds: Math.max(retryAfterSeconds, 1) };
    }

    // Check per-hour limit
    if (this.timestamps.length >= this.maxPerHour) {
      const oldestInWindow = this.timestamps[0];
      const retryAfterSeconds = Math.ceil((oldestInWindow + 60 * 60 * 1000 - now) / 1000);
      return { allowed: false, retryAfterSeconds: Math.max(retryAfterSeconds, 1) };
    }

    // Allowed — record this request
    this.timestamps.push(now);
    return { allowed: true };
  }
}

const rateLimiter = rateLimitConfig.enabled
  ? new RateLimiter({
      maxPerMinute: rateLimitConfig.maxTasksPerMinute ?? 10,
      maxPerHour: rateLimitConfig.maxTasksPerHour ?? 100,
    })
  : null;

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/** @type {Map<string, { ws: import('ws').WebSocket, status: string, connectedAt: string, workingDir: string|null }>} */
const workers = new Map();

let registry; // initialized in main()
let audit;    // initialized in main()
let taskQueue; // initialized in main()

// Queue configuration
const queueConfig = config.queue || { enabled: false };

// ---------------------------------------------------------------------------
// Dispatch helper — sends a task to a worker over WebSocket
// ---------------------------------------------------------------------------

function dispatchToWorker(task, worker, machineId) {
  worker.ws.send(JSON.stringify({
    type: 'task',
    taskId: task.id,
    prompt: task.prompt,
    workingDir: task.workingDir,
    timeout: 120000,
  }));
  console.log(`[relay] Dispatched task ${task.id} to ${machineId}`);
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

function cors(req, res) {
  // Restrict CORS to the request's own origin (dashboard on same host)
  const origin = req && req.headers && req.headers.origin;
  if (origin) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Content-Type', 'application/json');
}

function sendJSON(res, statusCode, body) {
  cors(res._req, res);
  res.writeHead(statusCode);
  res.end(JSON.stringify(body));
}

function authenticate(req) {
  const auth = req.headers['authorization'];
  if (!auth || !auth.startsWith('Bearer ')) return false;
  return auth.slice(7) === ADMIN_SECRET;
}

function sendUnauthorized(req, res) {
  cors(req, res);
  res.setHeader('WWW-Authenticate', 'Bearer');
  res.writeHead(401);
  res.end(JSON.stringify({ error: 'Unauthorized' }));
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;
    req.on('data', (c) => {
      totalBytes += c.length;
      if (maxBytes && totalBytes > maxBytes) {
        req.destroy();
        reject(new RangeError(`Request body exceeds ${maxBytes} bytes`));
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()));
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

// ---------------------------------------------------------------------------
// Path sanitization
// ---------------------------------------------------------------------------

/**
 * Validate and sanitize a working directory path.
 * Throws an Error if the path is unsafe.
 *
 * @param {string} dir - the directory path to validate
 * @returns {string} the sanitized path
 */
function sanitizeWorkingDir(dir) {
  if (!dir || typeof dir !== 'string') {
    throw new Error('Working directory must be a non-empty string');
  }

  // Reject null bytes
  if (dir.includes('\0')) {
    throw new Error('Path contains null bytes');
  }

  // Reject path traversal segments (..)
  // Normalize separators first so we catch both / and \ variants
  const normalized = dir.replace(/\\/g, '/');
  const segments = normalized.split('/');
  for (const seg of segments) {
    if (seg === '..') {
      throw new Error('Path contains ".." traversal segment');
    }
  }

  // Reject UNC paths (\\server\share or //server/share)
  if (/^\/\//.test(normalized) || /^\\\\/.test(dir)) {
    throw new Error('UNC paths are not allowed');
  }

  return dir;
}

// ---------------------------------------------------------------------------
// HTTP request handler
// ---------------------------------------------------------------------------

async function handleRequest(req, res) {
  res._req = req; // Attach req to res so sendJSON can access it for CORS
  const url = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  // CORS preflight
  if (req.method === 'OPTIONS') {
    cors(req, res);
    res.writeHead(204);
    res.end();
    return;
  }

  // --- Static dashboard serving ---
  const MIME_TYPES = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.ico': 'image/x-icon',
    '.json': 'application/json',
    '.png': 'image/png',
    '.svg': 'image/svg+xml',
  };

  if (req.method === 'GET' && pathname === '/dashboard') {
    const filePath = path.resolve(__dirname, '..', 'dashboard', 'index.html');
    try {
      const content = fs.readFileSync(filePath, 'utf-8');
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(content);
    } catch {
      sendJSON(res, 404, { error: 'Dashboard file not found' });
    }
    return;
  }

  const dashMatch = pathname.match(/^\/dashboard\/(.+)$/);
  if (req.method === 'GET' && dashMatch) {
    const safeName = path.basename(dashMatch[1]);
    const filePath = path.resolve(__dirname, '..', 'dashboard', safeName);
    const ext = path.extname(safeName).toLowerCase();
    const mimeType = MIME_TYPES[ext] || 'application/octet-stream';
    try {
      const content = fs.readFileSync(filePath);
      res.setHeader('Access-Control-Allow-Origin', '*');
      res.writeHead(200, { 'Content-Type': mimeType });
      res.end(content);
    } catch {
      sendJSON(res, 404, { error: 'File not found' });
    }
    return;
  }

  // Silently ignore favicon requests (browsers auto-request this)
  if (req.method === 'GET' && pathname === '/favicon.ico') {
    res.writeHead(204);
    res.end();
    return;
  }

  // --- Authentication for API endpoints ---
  if (!authenticate(req)) {
    const ip = req.socket.remoteAddress;
    const auth = req.headers['authorization'];
    const reason = !auth ? 'missing header' : !auth.startsWith('Bearer ') ? 'malformed header' : 'wrong token';
    audit.security('auth.failed', { ip, reason });
    sendUnauthorized(req, res);
    return;
  }

  // GET /status
  if (req.method === 'GET' && pathname === '/status') {
    const list = [];
    for (const [machineId, info] of workers) {
      list.push({
        machineId,
        status: info.status,
        connectedAt: info.connectedAt,
        workingDir: info.workingDir,
        agentName: info.agentName || null,
        agentDescription: info.agentDescription || null,
        agentCapabilities: info.agentCapabilities || [],
      });
    }
    sendJSON(res, 200, list);
    return;
  }

  // GET /tasks — list all tasks with filtering & pagination
  if (req.method === 'GET' && pathname === '/tasks') {
    const filters = {};
    const statusParam = url.searchParams.get('status');
    const machineIdParam = url.searchParams.get('machineId');
    const limitParam = url.searchParams.get('limit');
    const offsetParam = url.searchParams.get('offset');

    if (statusParam) filters.status = statusParam;
    if (machineIdParam) filters.machineId = machineIdParam;
    if (limitParam) filters.limit = parseInt(limitParam, 10);
    if (offsetParam) filters.offset = parseInt(offsetParam, 10);

    const tasks = registry.listTasks(filters);
    const total = registry.countTasks({
      status: filters.status,
      machineId: filters.machineId,
    });

    sendJSON(res, 200, { tasks, total });
    return;
  }

  // GET /task/:id
  const taskMatch = pathname.match(/^\/task\/(.+)$/);
  if (req.method === 'GET' && taskMatch) {
    const task = registry.getTask(taskMatch[1]);
    if (!task) {
      sendJSON(res, 404, { error: 'Task not found' });
    } else {
      sendJSON(res, 200, task);
    }
    return;
  }

  // POST /task
  if (req.method === 'POST' && pathname === '/task') {
    // --- Content-Length pre-check ---
    const contentLength = parseInt(req.headers['content-length'], 10);
    if (!isNaN(contentLength) && contentLength > MAX_REQUEST_BODY_BYTES) {
      sendJSON(res, 413, { error: `Request body too large. Max ${MAX_REQUEST_BODY_BYTES} bytes` });
      return;
    }

    // --- Rate limiting ---
    if (rateLimiter) {
      const check = rateLimiter.check();
      if (!check.allowed) {
        const ip = req.socket.remoteAddress;
        audit.warn('rate.limited', { ip, currentCount: rateLimiter.timestamps.length });
        cors(req, res);
        res.setHeader('Retry-After', String(check.retryAfterSeconds));
        res.writeHead(429);
        res.end(JSON.stringify({ error: 'Rate limit exceeded', retryAfterSeconds: check.retryAfterSeconds }));
        return;
      }
    }

    // --- Read body with byte limit ---
    let body;
    try {
      body = await readBody(req, MAX_REQUEST_BODY_BYTES);
    } catch (err) {
      if (err instanceof RangeError) {
        sendJSON(res, 413, { error: `Request body too large. Max ${MAX_REQUEST_BODY_BYTES} bytes` });
        return;
      }
      sendJSON(res, 400, { error: 'Invalid JSON body' });
      return;
    }

    // --- PIN verification ---
    if (pinConfig.enabled) {
      const ip = req.socket.remoteAddress;
      const lockout = pinLockouts.get(ip);

      // Check if IP is locked out
      if (lockout && lockout.lockedUntil && Date.now() < lockout.lockedUntil) {
        const retryAfterMinutes = Math.ceil((lockout.lockedUntil - Date.now()) / 60000);
        audit.security('pin.lockout.active', { ip, retryAfterMinutes });
        sendJSON(res, 403, { error: 'Locked out', retryAfterMinutes });
        return;
      }

      // Clear expired lockout
      if (lockout && lockout.lockedUntil && Date.now() >= lockout.lockedUntil) {
        pinLockouts.delete(ip);
      }

      // Verify PIN
      if (!body.pin || body.pin !== pinConfig.code) {
        const entry = pinLockouts.get(ip) || { failures: 0, lockedUntil: null };
        entry.failures++;
        audit.security('pin.failed', { ip, failures: entry.failures });

        if (entry.failures >= (pinConfig.maxAttempts ?? 5)) {
          entry.lockedUntil = Date.now() + (pinConfig.lockoutMinutes ?? 15) * 60000;
          pinLockouts.set(ip, entry);
          const retryAfterMinutes = pinConfig.lockoutMinutes ?? 15;
          audit.security('pin.lockout.triggered', { ip, lockoutMinutes: retryAfterMinutes });
          sendJSON(res, 403, { error: 'Locked out', retryAfterMinutes });
          return;
        }

        pinLockouts.set(ip, entry);
        sendJSON(res, 403, { error: 'Invalid PIN' });
        return;
      }

      // PIN correct — reset failures for this IP
      if (pinLockouts.has(ip)) {
        pinLockouts.delete(ip);
      }
    }

    let { machineId, prompt, workingDir, agentName } = body;

    // --- Agent name resolution ---
    // If agentName is provided instead of machineId, look up the machine by agent name
    if (agentName && typeof agentName === 'string' && (!machineId || machineId === '')) {
      const agentNameLower = agentName.toLowerCase();
      for (const [mid, w] of workers) {
        if (w.agentName && w.agentName.toLowerCase() === agentNameLower) {
          machineId = mid;
          break;
        }
      }
      if (!machineId) {
        sendJSON(res, 404, { error: `No agent named "${agentName}" is connected` });
        return;
      }
    }

    // --- Input validation ---
    if (!machineId || typeof machineId !== 'string' || machineId.length === 0 || machineId.length > 100) {
      sendJSON(res, 400, { error: 'machineId must be a non-empty string (max 100 chars)' });
      return;
    }
    if (!prompt || typeof prompt !== 'string') {
      sendJSON(res, 400, { error: 'machineId and prompt are required' });
      return;
    }
    if (prompt.length > MAX_PROMPT_LENGTH) {
      sendJSON(res, 400, { error: `prompt exceeds maximum length of ${MAX_PROMPT_LENGTH} characters` });
      return;
    }

    // --- Prompt content safety check ---
    // Block requests that attempt to exfiltrate system info or credentials
    const unsafePatterns = [
      { pattern: /(?:cat|type|print|read|get-content)\s+.*(?:\/etc\/passwd|\/etc\/shadow|\.env|\.pem|\.key|credentials)/i, reason: 'Attempt to read credential/system files' },
      { pattern: /(?:whoami|hostname|systeminfo|ipconfig|ifconfig|net\s+user)\s*[|>]/i, reason: 'System info exfiltration with output redirect' },
      { pattern: /(?:dump|export|exfiltrate|steal|extract)\s+.*(?:password|credential|secret|token|key)/i, reason: 'Credential exfiltration attempt' },
      { pattern: /curl\s+.*(?:webhook|requestbin|ngrok|burp|pipedream)/i, reason: 'Data exfiltration via external service' },
      { pattern: /\b(reg\s+query|reg\s+export|wmic)\b/i, reason: 'Windows registry/WMI access' },
      { pattern: /\b(Get-Credential|Export-PSCredential|ConvertTo-SecureString)\b/i, reason: 'PowerShell credential access' },
      { pattern: /\\\\[^\s\\]+\\[^\s\\]+/i, reason: 'UNC/SMB path access attempt' },
    ];

    for (const { pattern, reason } of unsafePatterns) {
      if (pattern.test(prompt)) {
        audit.security('prompt.blocked', { ip: req.socket.remoteAddress, reason });
        sendJSON(res, 400, { error: `Prompt rejected: ${reason}` });
        return;
      }
    }
    if (workingDir !== undefined && workingDir !== null) {
      if (typeof workingDir !== 'string' || workingDir.length === 0 || workingDir.length > 500) {
        sendJSON(res, 400, { error: 'workingDir must be a non-empty string (max 500 chars)' });
        return;
      }
    }

    // Sanitize workingDir if provided
    if (workingDir) {
      try {
        sanitizeWorkingDir(workingDir);
      } catch (err) {
        audit.security('path.denied', { machineId, attemptedPath: workingDir, reason: err.message });
        sendJSON(res, 400, { error: `Invalid working directory: ${err.message}` });
        return;
      }
    }

    // Determine the target worker and whether we can dispatch immediately
    let targetWorker = null;
    let targetMachineId = null;

    if (machineId === 'any') {
      // Find any idle worker
      for (const [mid, w] of workers) {
        if (w.status === 'idle') {
          targetWorker = w;
          targetMachineId = mid;
          break;
        }
      }
    } else {
      const worker = workers.get(machineId);
      if (worker && worker.status === 'idle') {
        targetWorker = worker;
        targetMachineId = machineId;
      }
    }

    // Resolve the working directory
    const resolvedWorkingDir = workingDir ?? (targetWorker ? targetWorker.workingDir : null);

    // Create task in registry
    const task = registry.createTask({ machineId, prompt, workingDir: resolvedWorkingDir });

    audit.log('task.submitted', {
      machineId,
      prompt: prompt.slice(0, 200),
      workingDir: resolvedWorkingDir,
    });

    if (targetWorker) {
      // Dispatch immediately
      registry.updateTask(task.id, { status: 'running' });
      registry.save();
      targetWorker.status = 'busy';
      dispatchToWorker(task, targetWorker, targetMachineId);
      sendJSON(res, 201, { ...task, status: 'running' });
    } else if (queueConfig.enabled && taskQueue) {
      // Queue the task for later dispatch
      try {
        const queued = taskQueue.enqueue(task);
        sendJSON(res, 202, { task: queued, queued: true, queuePosition: queued.queuePosition });
      } catch (err) {
        sendJSON(res, 400, { error: err.message });
      }
    } else {
      // Queue disabled — reject with original error behavior
      if (machineId === 'any') {
        sendJSON(res, 400, { error: 'No idle machines available' });
      } else {
        const worker = workers.get(machineId);
        if (!worker) {
          sendJSON(res, 400, { error: `Machine "${machineId}" is not connected` });
        } else {
          sendJSON(res, 400, { error: `Machine "${machineId}" is busy` });
        }
      }
    }
    return;
  }

  // GET /queue — queue status
  if (req.method === 'GET' && pathname === '/queue') {
    if (!queueConfig.enabled || !taskQueue) {
      sendJSON(res, 200, { enabled: false, length: 0, tasks: [] });
    } else {
      sendJSON(res, 200, {
        enabled: true,
        length: taskQueue.getQueueLength(),
        tasks: taskQueue.getQueuedTasks(),
      });
    }
    return;
  }

  // GET /stats — per-machine statistics for load balancing
  if (req.method === 'GET' && pathname === '/stats') {
    const oneHourAgo = Date.now() - 60 * 60 * 1000;
    const allTasks = registry.listTasks();

    // Group tasks by machine
    const byMachine = new Map();
    for (const t of allTasks) {
      if (!byMachine.has(t.machineId)) {
        byMachine.set(t.machineId, []);
      }
      byMachine.get(t.machineId).push(t);
    }

    // Build stats for every known machine (connected + any with history)
    const machineIds = new Set([
      ...workers.keys(),
      ...byMachine.keys(),
    ]);

    const stats = [];
    for (const machineId of machineIds) {
      const tasks = byMachine.get(machineId) || [];

      // Tasks completed in the last hour
      const recentDone = tasks.filter(
        (t) => t.status === 'done' && t.updatedAt >= oneHourAgo
      );
      const completedTasks1h = recentDone.length;

      // Average durationMs across last 10 completed tasks (all time)
      const completedWithDuration = tasks
        .filter((t) => t.status === 'done' && t.durationMs != null)
        .slice(-10);
      const avgDurationMs =
        completedWithDuration.length > 0
          ? Math.round(
              completedWithDuration.reduce((sum, t) => sum + t.durationMs, 0) /
                completedWithDuration.length
            )
          : null;

      // Error rate (all time)
      const totalFinished = tasks.filter((t) =>
        ['done', 'error', 'timeout'].includes(t.status)
      ).length;
      const errorCount = tasks.filter((t) =>
        ['error', 'timeout'].includes(t.status)
      ).length;
      const errorRate =
        totalFinished > 0
          ? Math.round((errorCount / totalFinished) * 10000) / 10000
          : 0;

      // Last task timestamp
      const lastTask = tasks.length > 0 ? tasks[0] : null; // tasks are ordered DESC
      const lastTaskAt = lastTask
        ? new Date(lastTask.updatedAt).toISOString()
        : null;

      const worker = workers.get(machineId);
      stats.push({
        machineId,
        status: worker ? worker.status : 'disconnected',
        completedTasks1h,
        avgDurationMs,
        errorRate,
        lastTaskAt,
      });
    }

    sendJSON(res, 200, stats);
    return;
  }

  // GET /audit — retrieve audit log entries
  if (req.method === 'GET' && pathname === '/audit') {
    const limitParam = url.searchParams.get('limit');
    const eventParam = url.searchParams.get('event');
    const levelParam = url.searchParams.get('level');
    const limit = limitParam ? parseInt(limitParam, 10) : 100;

    try {
      const logPath = audit.getLogPath();
      if (!fs.existsSync(logPath)) {
        sendJSON(res, 200, []);
        return;
      }
      const lines = fs.readFileSync(logPath, 'utf-8')
        .split('\n')
        .filter((line) => line.trim().length > 0);

      // Take last N lines
      let entries = lines.slice(-limit).map((line) => {
        try { return JSON.parse(line); } catch { return null; }
      }).filter(Boolean);

      // Apply filters
      if (eventParam) {
        entries = entries.filter((e) => e.event === eventParam);
      }
      if (levelParam) {
        entries = entries.filter((e) => e.level === levelParam);
      }

      sendJSON(res, 200, entries);
    } catch (err) {
      console.error('[relay] Failed to read audit log:', err.message);
      sendJSON(res, 500, { error: 'Failed to read audit log' });
    }
    return;
  }

  // -----------------------------------------------------------------------
  // Admin: machine enrollment and management
  // -----------------------------------------------------------------------

  // POST /admin/enroll — enroll a new machine, returns its API key
  if (req.method === 'POST' && pathname === '/admin/enroll') {
    if (!authenticate(req)) { sendUnauthorized(req, res); return; }
    const body = await readBody(req);
    const { machineId: mId, agentName: aName } = body;
    if (!mId || typeof mId !== 'string') {
      sendJSON(res, 400, { error: 'machineId is required' });
      return;
    }
    try {
      const result = registry.enrollMachine({ machineId: mId, agentName: aName });
      registry.save();
      audit.log('admin.enroll', { machineId: mId });
      sendJSON(res, 201, result);
    } catch (err) {
      sendJSON(res, 409, { error: err.message });
    }
    return;
  }

  // POST /admin/revoke — revoke a machine's API key
  if (req.method === 'POST' && pathname === '/admin/revoke') {
    if (!authenticate(req)) { sendUnauthorized(req, res); return; }
    const body = await readBody(req);
    const { machineId: mId } = body;
    if (!mId) {
      sendJSON(res, 400, { error: 'machineId is required' });
      return;
    }
    const result = registry.revokeMachine(mId);
    if (!result) {
      sendJSON(res, 404, { error: 'Machine not found' });
      return;
    }
    // Disconnect the worker if connected
    const worker = workers.get(mId);
    if (worker && worker.ws.readyState === 1) {
      worker.ws.close(4003, 'API key revoked');
      workers.delete(mId);
    }
    registry.save();
    audit.log('admin.revoke', { machineId: mId });
    sendJSON(res, 200, result);
    return;
  }

  // POST /admin/reenroll — generate a new API key for a revoked machine
  if (req.method === 'POST' && pathname === '/admin/reenroll') {
    if (!authenticate(req)) { sendUnauthorized(req, res); return; }
    const body = await readBody(req);
    const { machineId: mId, agentName: aName } = body;
    if (!mId) {
      sendJSON(res, 400, { error: 'machineId is required' });
      return;
    }
    const existing = registry.getMachine(mId);
    if (!existing) {
      sendJSON(res, 404, { error: 'Machine not found' });
      return;
    }
    try {
      const result = registry.enrollMachine({ machineId: mId, agentName: aName || existing.agentName });
      registry.save();
      audit.log('admin.reenroll', { machineId: mId });
      sendJSON(res, 200, result);
    } catch (err) {
      sendJSON(res, 409, { error: err.message });
    }
    return;
  }

  // GET /admin/machines — list enrolled machines with live status
  if (req.method === 'GET' && pathname === '/admin/machines') {
    if (!authenticate(req)) { sendUnauthorized(req, res); return; }
    const machines = registry.listMachines().map(m => {
      const worker = workers.get(m.machineId);
      return {
        ...m,
        connected: !!worker,
        workerStatus: worker?.status || null,
      };
    });
    sendJSON(res, 200, machines);
    return;
  }

  // Fallback
  sendJSON(res, 404, { error: 'Not found' });
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  audit = initAudit();
  console.log('[relay] Audit logger initialized');

  registry = await initRegistry();
  console.log('[relay] Task registry initialized');

  // Purge completed tasks older than 7 days on startup and daily
  const PURGE_DAYS = 7;
  const purged = registry.purgeTasks(PURGE_DAYS);
  if (purged > 0) {
    console.log(`[relay] Purged ${purged} completed tasks older than ${PURGE_DAYS} days`);
    registry.save();
  }
  setInterval(() => {
    const n = registry.purgeTasks(PURGE_DAYS);
    if (n > 0) {
      console.log(`[relay] Purged ${n} completed tasks older than ${PURGE_DAYS} days`);
      registry.save();
    }
  }, 24 * 60 * 60 * 1000);

  // Initialize task queue
  if (queueConfig.enabled) {
    taskQueue = createTaskQueue(registry, workers, dispatchToWorker, {
      maxQueueSize: queueConfig.maxQueueSize ?? 100,
    });
    console.log(`[relay] Task queue enabled (max size: ${queueConfig.maxQueueSize ?? 100})`);
  }

  // HTTP(S) server — use TLS if configured
  let server;
  const tlsEnabled = config.tls && config.tls.enabled;

  if (tlsEnabled) {
    const tlsOptions = {
      cert: fs.readFileSync(path.resolve(__dirname, config.tls.certFile)),
      key: fs.readFileSync(path.resolve(__dirname, config.tls.keyFile)),
      ca: fs.readFileSync(path.resolve(__dirname, config.tls.caFile)),
      requestCert: true,
      rejectUnauthorized: true,
    };
    server = https.createServer(tlsOptions, handleRequest);
    console.log('[relay] TLS enabled — using HTTPS/WSS');
  } else {
    server = http.createServer(handleRequest);
    console.log('[relay] TLS disabled — using plain HTTP/WS');
  }

  // WebSocket server — mounted on the same HTTP server
  const wss = new WebSocketServer({ server });

  // Handle server startup errors (port in use, etc.)
  function handleServerError(err) {
    if (err.code === 'EADDRINUSE') {
      console.error('');
      console.error(`[relay] ERROR: Port ${PORT} is already in use.`);
      console.error(`[relay] Another relay or application is running on this port.`);
      console.error('');
      console.error(`[relay] To find what's using it:`);
      console.error(`        netstat -ano | findstr :${PORT}`);
      console.error('');
      console.error(`[relay] To stop it:`);
      console.error(`        powershell -Command "Stop-Process -Id (Get-NetTCPConnection -LocalPort ${PORT}).OwningProcess -Force"`);
      console.error('');
    } else {
      console.error(`[relay] ERROR: ${err.message}`);
    }
    process.exit(1);
  }
  server.on('error', handleServerError);
  wss.on('error', handleServerError);

  wss.on('connection', (ws) => {
    let machineId = null;
    let registered = false;

    // Give the client 10 seconds to send a register message
    const registerTimeout = setTimeout(() => {
      if (!registered) {
        ws.close(4001, 'Registration timeout');
      }
    }, 10000);

    ws.on('message', (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }

      // --- Register ---
      if (msg.type === 'register') {
        // Authenticate: per-machine API key first, then legacy shared secret
        const machine = registry.getMachineByApiKey(msg.token);
        if (machine) {
          if (machine.revoked) {
            audit.security('auth.failed', { ip: ws._socket.remoteAddress, reason: 'revoked API key' });
            ws.close(4003, 'API key revoked');
            clearTimeout(registerTimeout);
            return;
          }
          if (machine.machineId !== msg.machineId) {
            audit.security('auth.failed', { ip: ws._socket.remoteAddress, reason: 'machineId mismatch' });
            ws.close(4003, 'machineId does not match API key');
            clearTimeout(registerTimeout);
            return;
          }
          registry.updateLastSeen(msg.machineId);
          registry.save();
        } else if (LEGACY_AUTH_ENABLED && msg.token === SHARED_SECRET) {
          // Legacy shared secret fallback
        } else {
          audit.security('auth.failed', { ip: ws._socket.remoteAddress, reason: 'wrong token' });
          ws.close(4003, 'Invalid token');
          clearTimeout(registerTimeout);
          return;
        }

        machineId = msg.machineId;

        // Validate machineId format
        if (!machineId || typeof machineId !== 'string' || machineId.length > 128 ||
            !/^[a-zA-Z0-9_\-\.]+$/.test(machineId)) {
          audit.security('auth.failed', { ip: ws._socket.remoteAddress, reason: 'invalid machineId' });
          ws.close(4004, 'Invalid machineId');
          clearTimeout(registerTimeout);
          return;
        }

        registered = true;
        clearTimeout(registerTimeout);

        // Close existing connection if this machineId is already registered
        const existing = workers.get(machineId);
        if (existing && existing.ws !== ws && existing.ws.readyState === 1) {
          audit.log('worker.replaced', { machineId, ip: ws._socket.remoteAddress });
          console.log(`[relay] Closing stale connection for ${machineId}`);
          existing.ws.close(4005, 'Replaced by new connection');
        }

        // Look up default workingDir from config
        const machineConfig = (config.machines || []).find(
          (m) => m.machineId === machineId
        );

        // Validate agentCapabilities is a string array
        let caps = [];
        if (Array.isArray(msg.agentCapabilities) &&
            msg.agentCapabilities.every(c => typeof c === 'string')) {
          caps = msg.agentCapabilities;
        }

        workers.set(machineId, {
          ws,
          status: 'idle',
          connectedAt: new Date().toISOString(),
          workingDir: machineConfig?.defaultWorkingDir ?? null,
          lastPong: Date.now(),
          agentName: typeof msg.agentName === 'string' ? msg.agentName : (machine?.agentName || null),
          agentDescription: typeof msg.agentDescription === 'string' ? msg.agentDescription : null,
          agentCapabilities: caps,
        });

        audit.log('worker.connected', { machineId, ip: ws._socket.remoteAddress });
        console.log(`[relay] Worker registered: ${machineId}`);
        return;
      }

      // --- Result ---
      if (msg.type === 'result' && registered) {
        const { taskId, status, output, durationMs } = msg;

        // Verify the result comes from the machine the task was dispatched to
        const task = registry.getTask(taskId);
        if (!task) {
          audit.security('result.invalid_task', { machineId, taskId });
          console.log(`[relay] Result for unknown task ${taskId} from ${machineId} — ignored`);
          return;
        }
        if (task.machineId !== machineId) {
          audit.security('result.wrong_machine', {
            taskId, expected: task.machineId, actual: machineId,
          });
          console.log(`[relay] Result for task ${taskId} from wrong machine ${machineId} (expected ${task.machineId}) — ignored`);
          return;
        }

        registry.updateTask(taskId, {
          status: status ?? 'done',
          output: output ?? null,
          durationMs: durationMs ?? null,
        });
        registry.save();

        // Mark worker idle again
        const worker = workers.get(machineId);
        if (worker) {
          worker.status = 'idle';
        }

        if (status === 'done') {
          audit.log('task.completed', { taskId, machineId, status, durationMs });
        } else {
          audit.error('task.error', { taskId, machineId, error: status, durationMs });
        }
        console.log(`[relay] Result received for task ${taskId} from ${machineId}: ${status}`);

        // Drain the queue now that a worker is idle
        if (taskQueue) {
          taskQueue.onWorkerIdle(machineId);
        }
        return;
      }

      // --- Pong (heartbeat response) ---
      if (msg.type === 'pong' && registered) {
        const worker = workers.get(machineId);
        if (worker) {
          worker.lastPong = Date.now();
        }
        return;
      }
    });

    ws.on('close', () => {
      clearTimeout(registerTimeout);
      if (machineId && workers.has(machineId)) {
        audit.warn('worker.disconnected', { machineId, reason: 'connection closed' });
        workers.delete(machineId);
        console.log(`[relay] Worker disconnected: ${machineId}`);
      }
    });

    ws.on('error', (err) => {
      console.error(`[relay] WebSocket error${machineId ? ` (${machineId})` : ''}:`, err.message);
    });
  });

  // Keep-awake: prevent system sleep while relay is running
  let keepAwakeHandle = null;
  if (config.keepAwake && config.keepAwake.enabled) {
    const { startKeepAwake } = await import('../lib/keep-awake.js');
    keepAwakeHandle = startKeepAwake({ enabled: true });
    console.log('[relay] Sleep prevention is active');
  }

  // ---------------------------------------------------------------------------
  // Heartbeat — detect zombie worker connections
  // ---------------------------------------------------------------------------

  const heartbeatInterval = setInterval(() => {
    const now = Date.now();
    for (const [id, worker] of workers) {
      // Send ping to each connected worker
      try {
        worker.ws.send(JSON.stringify({ type: 'ping', timestamp: now }));
      } catch {
        // send failed — will be caught by timeout check below
      }

      // Check if worker has exceeded the timeout since last pong
      // Allow heartbeat interval + timeout before declaring dead
      if (now - worker.lastPong > HEARTBEAT_INTERVAL + HEARTBEAT_TIMEOUT) {
        console.warn(`[relay] Worker ${id} failed heartbeat, disconnecting`);

        // Mark any running tasks for this worker as error
        const allTasks = registry.listTasks({ machineId: id, status: 'running' });
        for (const task of allTasks) {
          registry.updateTask(task.id, {
            status: 'error',
            output: 'Worker lost connection during task execution',
          });
        }
        registry.save();

        // Close the connection (triggers existing cleanup via 'close' event)
        worker.ws.close(4002, 'Heartbeat timeout');
      }
    }
  }, HEARTBEAT_INTERVAL);

  console.log(`[relay] Heartbeat active — interval=${HEARTBEAT_INTERVAL}ms timeout=${HEARTBEAT_TIMEOUT}ms`);

  // Start listening
  let discoveryHandle = null;

  server.listen(PORT, '0.0.0.0', async () => {
    console.log(`[relay] Ready — listening on 0.0.0.0:${PORT}`);

    // Start UDP discovery broadcast if enabled
    if (config.discovery && config.discovery.enabled) {
      const { startBroadcast } = await import('./discovery.js');
      const broadcastPort = config.discovery.broadcastPort ?? 7071;
      const intervalMs = config.discovery.intervalMs ?? 5000;
      discoveryHandle = startBroadcast(broadcastPort, PORT, intervalMs, SHARED_SECRET);
      console.log('[relay] Discovery broadcasting is active');
    }
  });

  // Graceful shutdown
  function shutdown(signal) {
    console.log(`\n[relay] ${signal} received, shutting down...`);
    if (keepAwakeHandle) {
      keepAwakeHandle.stop();
      keepAwakeHandle = null;
    }
    clearInterval(heartbeatInterval);
    if (discoveryHandle) {
      discoveryHandle.stop();
      discoveryHandle = null;
    }
    registry.save();

    for (const [id, worker] of workers) {
      worker.ws.close(1001, 'Server shutting down');
    }
    workers.clear();

    wss.close(() => {
      server.close(() => {
        console.log('[relay] Shutdown complete');
        process.exit(0);
      });
    });

    // Force exit after 5 seconds
    setTimeout(() => process.exit(1), 5000);
  }

  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

main().catch((err) => {
  console.error('[relay] Fatal error:', err);
  process.exit(1);
});
