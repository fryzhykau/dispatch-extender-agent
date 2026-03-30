import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { v4 as uuidv4 } from 'uuid';
import initSqlJs from 'sql.js';
import { getDataDir } from '../lib/data-dir.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const dataDir = getDataDir(path.resolve(__dirname, '..'));
const DB_PATH = path.join(dataDir, 'tasks.db');

const CREATE_TABLE_SQL = `
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

/**
 * Initializes the sql.js-backed SQLite task registry.
 * Loads existing DB from disk or creates a new one.
 * Returns a registry object with CRUD methods.
 */
export async function initRegistry() {
  const SQL = await initSqlJs();

  // Data directory is already ensured by getDataDir()

  // Load existing DB file or create a fresh database
  let db;
  if (fs.existsSync(DB_PATH)) {
    const fileBuffer = fs.readFileSync(DB_PATH);
    db = new SQL.Database(fileBuffer);
  } else {
    db = new SQL.Database();
  }

  // Ensure the tasks table exists
  db.run(CREATE_TABLE_SQL);

  // Helper: convert a result row (array of columns) into a plain object
  function rowToObject(columns, values) {
    const obj = {};
    for (let i = 0; i < columns.length; i++) {
      obj[columns[i]] = values[i];
    }
    return obj;
  }

  // Helper: run a SELECT and return an array of plain objects
  function queryAll(sql, params = []) {
    const stmt = db.prepare(sql);
    stmt.bind(params);
    const results = [];
    while (stmt.step()) {
      const row = stmt.getAsObject();
      results.push(row);
    }
    stmt.free();
    return results;
  }

  // Helper: run a SELECT and return the first row or null
  function queryOne(sql, params = []) {
    const rows = queryAll(sql, params);
    return rows.length > 0 ? rows[0] : null;
  }

  const registry = {
    /**
     * Insert a new task with a generated UUID.
     * Returns the created task object.
     */
    createTask({ machineId, prompt, workingDir }) {
      const id = uuidv4();
      const now = Date.now();

      db.run(
        `INSERT INTO tasks (id, machineId, prompt, workingDir, status, output, createdAt, updatedAt, durationMs)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [id, machineId, prompt, workingDir, 'pending', null, now, now, null]
      );

      return {
        id,
        machineId,
        prompt,
        workingDir,
        status: 'pending',
        output: null,
        createdAt: now,
        updatedAt: now,
        durationMs: null,
      };
    },

    /**
     * Retrieve a single task by ID, or null if not found.
     */
    getTask(id) {
      return queryOne('SELECT * FROM tasks WHERE id = ?', [id]);
    },

    /**
     * Update a subset of mutable fields on a task.
     * Allowed fields: status, output, durationMs.
     * Automatically sets updatedAt to now.
     */
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

      if (setClauses.length === 0) {
        return;
      }

      const now = Date.now();
      setClauses.push('updatedAt = ?');
      values.push(now);
      values.push(id);

      db.run(
        `UPDATE tasks SET ${setClauses.join(', ')} WHERE id = ?`,
        values
      );

      return queryOne('SELECT * FROM tasks WHERE id = ?', [id]);
    },

    /**
     * List tasks with optional filters and pagination.
     * @param {Object} [filters]
     * @param {string} [filters.status]    — filter by status
     * @param {string} [filters.machineId] — filter by machineId
     * @param {number} [filters.limit]     — max rows to return
     * @param {number} [filters.offset]    — rows to skip
     */
    listTasks(filters = {}) {
      const conditions = [];
      const values = [];

      if (filters.status) {
        conditions.push('status = ?');
        values.push(filters.status);
      }
      if (filters.machineId) {
        conditions.push('machineId = ?');
        values.push(filters.machineId);
      }

      let sql = 'SELECT * FROM tasks';
      if (conditions.length > 0) {
        sql += ' WHERE ' + conditions.join(' AND ');
      }
      sql += ' ORDER BY createdAt DESC';

      if (filters.limit != null) {
        sql += ' LIMIT ?';
        values.push(filters.limit);
      }
      if (filters.offset != null) {
        sql += ' OFFSET ?';
        values.push(filters.offset);
      }

      return queryAll(sql, values);
    },

    /**
     * Count tasks matching the given filters (for pagination).
     * @param {Object} [filters]
     * @param {string} [filters.status]    — filter by status
     * @param {string} [filters.machineId] — filter by machineId
     * @returns {number}
     */
    countTasks(filters = {}) {
      const conditions = [];
      const values = [];

      if (filters.status) {
        conditions.push('status = ?');
        values.push(filters.status);
      }
      if (filters.machineId) {
        conditions.push('machineId = ?');
        values.push(filters.machineId);
      }

      let sql = 'SELECT COUNT(*) as cnt FROM tasks';
      if (conditions.length > 0) {
        sql += ' WHERE ' + conditions.join(' AND ');
      }

      const row = queryOne(sql, values);
      return row ? row.cnt : 0;
    },

    /**
     * Persist the in-memory database to disk.
     * sql.js operates in memory; call this to write changes to the file.
     */
    save() {
      const data = db.export();
      const buffer = Buffer.from(data);
      fs.writeFileSync(DB_PATH, buffer);
    },
  };

  return registry;
}
