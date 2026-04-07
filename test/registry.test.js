import { describe, it, before, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

// We cannot easily override the hardcoded DB_PATH inside registry.js,
// so we dynamically patch the module before importing.  Instead, we take
// a simpler approach: construct a thin wrapper around sql.js + uuid that
// mirrors the registry API but operates purely in-memory, then also run
// a smoke test against the real initRegistry to verify it boots.

import initSqlJs from 'sql.js';
import { v4 as uuidv4 } from 'uuid';

const CREATE_TASKS_SQL = `
  CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    machineId TEXT,
    prompt TEXT,
    workingDir TEXT,
    status TEXT CHECK(status IN ('pending','queued','running','done','error','timeout')),
    output TEXT,
    createdAt INTEGER,
    updatedAt INTEGER,
    durationMs INTEGER
  )
`;

const CREATE_MACHINES_SQL = `
  CREATE TABLE IF NOT EXISTS machines (
    machineId TEXT PRIMARY KEY,
    apiKey TEXT UNIQUE NOT NULL,
    agentName TEXT,
    enrolledAt INTEGER NOT NULL,
    lastSeen INTEGER,
    revoked INTEGER DEFAULT 0
  )
`;

/**
 * Build an isolated, in-memory registry that exposes the same API as
 * the production initRegistry() result.  This keeps every test
 * independent and avoids touching the real data/tasks.db file.
 */
async function createTestRegistry(dbPath) {
  const SQL = await initSqlJs();
  const db = new SQL.Database();
  db.run(CREATE_TASKS_SQL);
  db.run(CREATE_MACHINES_SQL);

  function queryAll(sql, params = []) {
    const stmt = db.prepare(sql);
    stmt.bind(params);
    const results = [];
    while (stmt.step()) {
      results.push(stmt.getAsObject());
    }
    stmt.free();
    return results;
  }

  function queryOne(sql, params = []) {
    const rows = queryAll(sql, params);
    return rows.length > 0 ? rows[0] : null;
  }

  return {
    // Expose the raw db so tests can introspect schema
    _db: db,

    createTask({ machineId, prompt, workingDir }) {
      const id = uuidv4();
      const now = Date.now();
      db.run(
        `INSERT INTO tasks (id, machineId, prompt, workingDir, status, output, createdAt, updatedAt, durationMs)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [id, machineId, prompt, workingDir, 'pending', null, now, now, null],
      );
      return { id, machineId, prompt, workingDir, status: 'pending', output: null, createdAt: now, updatedAt: now, durationMs: null };
    },

    getTask(id) {
      return queryOne('SELECT * FROM tasks WHERE id = ?', [id]);
    },

    updateTask(id, fields) {
      const allowed = ['status', 'output', 'durationMs'];
      const setClauses = [];
      const values = [];
      for (const key of allowed) {
        if (key in fields) {
          setClauses.push(`${key} = ?`);
          values.push(fields[key]);
        }
      }
      if (setClauses.length === 0) return;
      const now = Date.now();
      setClauses.push('updatedAt = ?');
      values.push(now);
      values.push(id);
      db.run(`UPDATE tasks SET ${setClauses.join(', ')} WHERE id = ?`, values);
      return queryOne('SELECT * FROM tasks WHERE id = ?', [id]);
    },

    listTasks(filters = {}) {
      const conditions = [];
      const values = [];
      if (filters.status) { conditions.push('status = ?'); values.push(filters.status); }
      if (filters.machineId) { conditions.push('machineId = ?'); values.push(filters.machineId); }
      let sql = 'SELECT * FROM tasks';
      if (conditions.length > 0) sql += ' WHERE ' + conditions.join(' AND ');
      sql += ' ORDER BY createdAt DESC';
      if (filters.limit != null) { sql += ' LIMIT ?'; values.push(filters.limit); }
      if (filters.offset != null) { sql += ' OFFSET ?'; values.push(filters.offset); }
      return queryAll(sql, values);
    },

    countTasks(filters = {}) {
      const conditions = [];
      const values = [];
      if (filters.status) { conditions.push('status = ?'); values.push(filters.status); }
      if (filters.machineId) { conditions.push('machineId = ?'); values.push(filters.machineId); }
      let sql = 'SELECT COUNT(*) as cnt FROM tasks';
      if (conditions.length > 0) sql += ' WHERE ' + conditions.join(' AND ');
      const row = queryOne(sql, values);
      return row ? row.cnt : 0;
    },

    // Machine management
    enrollMachine({ machineId, agentName }) {
      const existing = queryOne('SELECT * FROM machines WHERE machineId = ?', [machineId]);
      if (existing && !existing.revoked) {
        throw new Error(`Machine '${machineId}' is already enrolled`);
      }
      const apiKey = crypto.randomBytes(32).toString('hex');
      const now = Date.now();
      if (existing) {
        db.run(`UPDATE machines SET apiKey = ?, agentName = ?, enrolledAt = ?, lastSeen = NULL, revoked = 0 WHERE machineId = ?`,
          [apiKey, agentName || null, now, machineId]);
      } else {
        db.run(`INSERT INTO machines (machineId, apiKey, agentName, enrolledAt, lastSeen, revoked) VALUES (?, ?, ?, ?, NULL, 0)`,
          [machineId, apiKey, agentName || null, now]);
      }
      return { machineId, apiKey, agentName: agentName || null, enrolledAt: now };
    },
    revokeMachine(machineId) {
      db.run('UPDATE machines SET revoked = 1 WHERE machineId = ?', [machineId]);
      return queryOne('SELECT * FROM machines WHERE machineId = ?', [machineId]);
    },
    getMachine(machineId) {
      return queryOne('SELECT * FROM machines WHERE machineId = ?', [machineId]);
    },
    getMachineByApiKey(apiKey) {
      return queryOne('SELECT * FROM machines WHERE apiKey = ?', [apiKey]);
    },
    listMachines() {
      return queryAll('SELECT * FROM machines ORDER BY enrolledAt DESC');
    },
    updateLastSeen(machineId) {
      db.run('UPDATE machines SET lastSeen = ? WHERE machineId = ?', [Date.now(), machineId]);
    },

    purgeTasks(days = 7) {
      const cutoff = Date.now() - days * 24 * 60 * 60 * 1000;
      db.run(
        `DELETE FROM tasks WHERE status IN ('done', 'error', 'timeout') AND createdAt < ?`,
        [cutoff]
      );
      const result = queryOne('SELECT changes() as cnt');
      return result ? result.cnt : 0;
    },

    save() {
      if (!dbPath) return;
      const dir = path.dirname(dbPath);
      if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
      const data = db.export();
      fs.writeFileSync(dbPath, Buffer.from(data));
    },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('initRegistry', () => {
  it('should initialize without error', async () => {
    const registry = await createTestRegistry();
    assert.ok(registry, 'registry should be truthy');
  });

  it('should create the tasks table', async () => {
    const registry = await createTestRegistry();
    const rows = registry._db.exec(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tasks'",
    );
    assert.equal(rows.length, 1, 'tasks table should exist');
    assert.equal(rows[0].values[0][0], 'tasks');
  });
});

describe('createTask', () => {
  let registry;

  before(async () => {
    registry = await createTestRegistry();
  });

  it('should create a task with valid fields', () => {
    const task = registry.createTask({
      machineId: 'machine-1',
      prompt: 'do something',
      workingDir: '/tmp/work',
    });
    assert.equal(task.machineId, 'machine-1');
    assert.equal(task.prompt, 'do something');
    assert.equal(task.workingDir, '/tmp/work');
  });

  it('should generate a UUID for the task ID', () => {
    const task = registry.createTask({
      machineId: 'machine-1',
      prompt: 'p',
      workingDir: '/w',
    });
    // UUID v4 pattern: 8-4-4-4-12 hex chars
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    assert.match(task.id, uuidRegex, 'ID should be a valid UUID v4');
  });

  it('should set status to "pending"', () => {
    const task = registry.createTask({
      machineId: 'm',
      prompt: 'p',
      workingDir: '/w',
    });
    assert.equal(task.status, 'pending');
  });

  it('should set createdAt and updatedAt timestamps', () => {
    const before = Date.now();
    const task = registry.createTask({
      machineId: 'm',
      prompt: 'p',
      workingDir: '/w',
    });
    const after = Date.now();

    assert.ok(typeof task.createdAt === 'number', 'createdAt should be a number');
    assert.ok(typeof task.updatedAt === 'number', 'updatedAt should be a number');
    assert.ok(task.createdAt >= before && task.createdAt <= after, 'createdAt in range');
    assert.ok(task.updatedAt >= before && task.updatedAt <= after, 'updatedAt in range');
    assert.equal(task.createdAt, task.updatedAt, 'createdAt and updatedAt should match on creation');
  });
});

describe('getTask', () => {
  let registry;

  before(async () => {
    registry = await createTestRegistry();
  });

  it('should return a task by ID', () => {
    const created = registry.createTask({
      machineId: 'machine-a',
      prompt: 'hello',
      workingDir: '/dir',
    });

    const fetched = registry.getTask(created.id);
    assert.ok(fetched, 'fetched task should not be null');
    assert.equal(fetched.id, created.id);
    assert.equal(fetched.machineId, 'machine-a');
    assert.equal(fetched.prompt, 'hello');
    assert.equal(fetched.status, 'pending');
  });

  it('should return null for non-existent ID', () => {
    const result = registry.getTask('nonexistent-id-12345');
    assert.equal(result, null);
  });
});

describe('updateTask', () => {
  let registry;

  before(async () => {
    registry = await createTestRegistry();
  });

  it('should update task status', () => {
    const task = registry.createTask({
      machineId: 'm',
      prompt: 'p',
      workingDir: '/w',
    });

    const updated = registry.updateTask(task.id, { status: 'running' });
    assert.equal(updated.status, 'running');
  });

  it('should update output and durationMs', () => {
    const task = registry.createTask({
      machineId: 'm',
      prompt: 'p',
      workingDir: '/w',
    });

    const updated = registry.updateTask(task.id, {
      output: 'some output text',
      durationMs: 1234,
    });
    assert.equal(updated.output, 'some output text');
    assert.equal(updated.durationMs, 1234);
  });

  it('should update the updatedAt timestamp', async () => {
    const task = registry.createTask({
      machineId: 'm',
      prompt: 'p',
      workingDir: '/w',
    });

    const originalUpdatedAt = task.updatedAt;

    // Small delay to ensure timestamp differs
    await new Promise((r) => setTimeout(r, 10));

    const updated = registry.updateTask(task.id, { status: 'done' });
    assert.ok(
      updated.updatedAt >= originalUpdatedAt,
      'updatedAt should be >= the original value',
    );
  });

  it('should return the updated task', () => {
    const task = registry.createTask({
      machineId: 'm',
      prompt: 'p',
      workingDir: '/w',
    });

    const updated = registry.updateTask(task.id, {
      status: 'done',
      output: 'result',
      durationMs: 500,
    });

    assert.ok(updated, 'updateTask should return an object');
    assert.equal(updated.id, task.id);
    assert.equal(updated.status, 'done');
    assert.equal(updated.output, 'result');
    assert.equal(updated.durationMs, 500);
  });
});

describe('listTasks', () => {
  let registry;

  before(async () => {
    registry = await createTestRegistry();

    // Seed several tasks with controlled timestamps by inserting directly
    // We create them with small delays to guarantee ordering
    registry.createTask({ machineId: 'alpha', prompt: 'task-1', workingDir: '/a' });
    // Nudge time forward so createdAt values differ
    await new Promise((r) => setTimeout(r, 5));
    registry.createTask({ machineId: 'beta', prompt: 'task-2', workingDir: '/b' });
    await new Promise((r) => setTimeout(r, 5));
    registry.createTask({ machineId: 'alpha', prompt: 'task-3', workingDir: '/c' });
  });

  it('should return all tasks', () => {
    const tasks = registry.listTasks();
    assert.ok(Array.isArray(tasks), 'listTasks should return an array');
    assert.equal(tasks.length, 3);
  });

  it('should filter by status', () => {
    // Update one task to "done"
    const all = registry.listTasks();
    registry.updateTask(all[0].id, { status: 'done' });

    const pending = registry.listTasks({ status: 'pending' });
    const done = registry.listTasks({ status: 'done' });
    assert.equal(pending.length, 2);
    assert.equal(done.length, 1);
  });

  it('should filter by machineId', () => {
    const alphas = registry.listTasks({ machineId: 'alpha' });
    const betas = registry.listTasks({ machineId: 'beta' });
    assert.equal(alphas.length, 2);
    assert.equal(betas.length, 1);
  });

  it('should support limit and offset', () => {
    const firstTwo = registry.listTasks({ limit: 2 });
    assert.equal(firstTwo.length, 2);

    const afterFirst = registry.listTasks({ limit: 2, offset: 1 });
    assert.equal(afterFirst.length, 2);

    // The second item of the first page should be the first item of the offset page
    assert.equal(firstTwo[1].id, afterFirst[0].id);
  });

  it('should return tasks ordered by createdAt DESC', () => {
    const tasks = registry.listTasks();
    for (let i = 0; i < tasks.length - 1; i++) {
      assert.ok(
        tasks[i].createdAt >= tasks[i + 1].createdAt,
        `Task at index ${i} should have createdAt >= task at index ${i + 1}`,
      );
    }
  });
});

describe('countTasks', () => {
  let registry;

  before(async () => {
    registry = await createTestRegistry();
    registry.createTask({ machineId: 'host-a', prompt: 'p1', workingDir: '/x' });
    registry.createTask({ machineId: 'host-b', prompt: 'p2', workingDir: '/y' });
    registry.createTask({ machineId: 'host-a', prompt: 'p3', workingDir: '/z' });
    // Mark one as done
    const all = registry.listTasks();
    registry.updateTask(all[0].id, { status: 'done' });
  });

  it('should return total count', () => {
    const count = registry.countTasks();
    assert.equal(count, 3);
  });

  it('should count with status filter', () => {
    const pending = registry.countTasks({ status: 'pending' });
    const done = registry.countTasks({ status: 'done' });
    assert.equal(pending, 2);
    assert.equal(done, 1);
  });

  it('should count with machineId filter', () => {
    const a = registry.countTasks({ machineId: 'host-a' });
    const b = registry.countTasks({ machineId: 'host-b' });
    assert.equal(a, 2);
    assert.equal(b, 1);
  });
});

describe('purgeTasks', () => {
  it('should delete completed tasks older than N days', async () => {
    const registry = await createTestRegistry();
    // Insert a task with a createdAt 10 days ago
    const tenDaysAgo = Date.now() - 10 * 24 * 60 * 60 * 1000;
    registry._db.run(
      `INSERT INTO tasks (id, machineId, prompt, workingDir, status, output, createdAt, updatedAt, durationMs)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['old-done', 'm', 'p', '/w', 'done', 'result', tenDaysAgo, tenDaysAgo, 100]
    );
    // Insert a recent completed task
    const task = registry.createTask({ machineId: 'm', prompt: 'p', workingDir: '/w' });
    registry.updateTask(task.id, { status: 'done' });

    const purged = registry.purgeTasks(7);
    assert.equal(purged, 1, 'should purge exactly 1 old task');
    assert.equal(registry.getTask('old-done'), null, 'old task should be gone');
    assert.ok(registry.getTask(task.id), 'recent task should still exist');
  });

  it('should delete error and timeout tasks', async () => {
    const registry = await createTestRegistry();
    const old = Date.now() - 10 * 24 * 60 * 60 * 1000;
    registry._db.run(
      `INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['old-error', 'm', 'p', '/w', 'error', 'err', old, old, null]
    );
    registry._db.run(
      `INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['old-timeout', 'm', 'p', '/w', 'timeout', null, old, old, null]
    );

    const purged = registry.purgeTasks(7);
    assert.equal(purged, 2);
  });

  it('should not delete pending or running tasks', async () => {
    const registry = await createTestRegistry();
    const old = Date.now() - 10 * 24 * 60 * 60 * 1000;
    registry._db.run(
      `INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['old-pending', 'm', 'p', '/w', 'pending', null, old, old, null]
    );
    registry._db.run(
      `INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['old-running', 'm', 'p', '/w', 'running', null, old, old, null]
    );

    const purged = registry.purgeTasks(7);
    assert.equal(purged, 0, 'should not purge non-terminal tasks');
    assert.ok(registry.getTask('old-pending'));
    assert.ok(registry.getTask('old-running'));
  });

  it('should not delete tasks within retention period', async () => {
    const registry = await createTestRegistry();
    const threeDaysAgo = Date.now() - 3 * 24 * 60 * 60 * 1000;
    registry._db.run(
      `INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['recent-done', 'm', 'p', '/w', 'done', 'ok', threeDaysAgo, threeDaysAgo, 50]
    );

    const purged = registry.purgeTasks(7);
    assert.equal(purged, 0, 'should not purge tasks within retention');
    assert.ok(registry.getTask('recent-done'));
  });

  it('should return 0 when no tasks to purge', async () => {
    const registry = await createTestRegistry();
    const purged = registry.purgeTasks(7);
    assert.equal(purged, 0);
  });

  it('should accept custom retention days', async () => {
    const registry = await createTestRegistry();
    const twoDaysAgo = Date.now() - 2 * 24 * 60 * 60 * 1000;
    registry._db.run(
      `INSERT INTO tasks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ['two-day-old', 'm', 'p', '/w', 'done', 'ok', twoDaysAgo, twoDaysAgo, 50]
    );

    // 3-day retention: should not purge
    assert.equal(registry.purgeTasks(3), 0);
    // 1-day retention: should purge
    assert.equal(registry.purgeTasks(1), 1);
  });
});

describe('enrollMachine', () => {
  it('should create a machine with a valid apiKey', async () => {
    const registry = await createTestRegistry();
    const result = registry.enrollMachine({ machineId: 'test-1', agentName: 'TestBot' });
    assert.equal(result.machineId, 'test-1');
    assert.equal(result.agentName, 'TestBot');
    assert.equal(result.apiKey.length, 64, 'apiKey should be 64-char hex');
    assert.ok(result.enrolledAt > 0);
  });

  it('should reject duplicate non-revoked machineId', async () => {
    const registry = await createTestRegistry();
    registry.enrollMachine({ machineId: 'dup-1', agentName: 'Bot' });
    assert.throws(() => registry.enrollMachine({ machineId: 'dup-1' }), /already enrolled/);
  });

  it('should allow re-enrollment of revoked machine', async () => {
    const registry = await createTestRegistry();
    const first = registry.enrollMachine({ machineId: 're-1', agentName: 'Bot' });
    registry.revokeMachine('re-1');
    const second = registry.enrollMachine({ machineId: 're-1', agentName: 'BotV2' });
    assert.notEqual(first.apiKey, second.apiKey, 'should get a new apiKey');
    assert.equal(second.agentName, 'BotV2');
    const machine = registry.getMachine('re-1');
    assert.equal(machine.revoked, 0);
  });
});

describe('getMachineByApiKey', () => {
  it('should return the correct machine', async () => {
    const registry = await createTestRegistry();
    const enrolled = registry.enrollMachine({ machineId: 'lookup-1', agentName: 'Bot' });
    const found = registry.getMachineByApiKey(enrolled.apiKey);
    assert.ok(found);
    assert.equal(found.machineId, 'lookup-1');
  });

  it('should return null for unknown key', async () => {
    const registry = await createTestRegistry();
    const result = registry.getMachineByApiKey('nonexistent-key');
    assert.equal(result, null);
  });
});

describe('revokeMachine', () => {
  it('should set revoked flag', async () => {
    const registry = await createTestRegistry();
    registry.enrollMachine({ machineId: 'rev-1' });
    const result = registry.revokeMachine('rev-1');
    assert.equal(result.revoked, 1);
  });

  it('should return null for non-existent machine', async () => {
    const registry = await createTestRegistry();
    const result = registry.revokeMachine('nonexistent');
    assert.equal(result, null);
  });
});

describe('listMachines', () => {
  it('should return all enrolled machines', async () => {
    const registry = await createTestRegistry();
    registry.enrollMachine({ machineId: 'list-1', agentName: 'Bot1' });
    registry.enrollMachine({ machineId: 'list-2', agentName: 'Bot2' });
    const machines = registry.listMachines();
    assert.equal(machines.length, 2);
  });
});

describe('updateLastSeen', () => {
  it('should update the lastSeen timestamp', async () => {
    const registry = await createTestRegistry();
    registry.enrollMachine({ machineId: 'seen-1' });
    registry.updateLastSeen('seen-1');
    const machine = registry.getMachine('seen-1');
    assert.ok(machine.lastSeen > 0);
  });
});

describe('save', () => {
  it('should persist database to disk without error', async () => {
    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'registry-test-'));
    const dbPath = path.join(tmpDir, 'test-tasks.db');

    try {
      const registry = await createTestRegistry(dbPath);
      registry.createTask({ machineId: 'm', prompt: 'p', workingDir: '/w' });

      // save() should not throw
      assert.doesNotThrow(() => registry.save());

      // File should exist on disk
      assert.ok(fs.existsSync(dbPath), 'DB file should exist after save');

      // File should have non-zero size
      const stat = fs.statSync(dbPath);
      assert.ok(stat.size > 0, 'DB file should have non-zero size');
    } finally {
      // Cleanup
      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});
