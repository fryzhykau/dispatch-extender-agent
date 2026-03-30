/**
 * test/queue.test.js
 *
 * Tests for the task queue module (relay/queue.js).
 */

import { describe, it, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createTaskQueue } from '../relay/queue.js';

// ---------------------------------------------------------------------------
// Mock registry — mimics the real SQLite-backed registry in memory
// ---------------------------------------------------------------------------

function createMockRegistry() {
  const tasks = new Map();
  let seqCounter = 0;

  return {
    createTask({ machineId, prompt, workingDir }) {
      const id = `task-${tasks.size + 1}`;
      // Use a monotonic counter to guarantee ordering even within the same ms
      const seq = ++seqCounter;
      const task = {
        id,
        machineId,
        prompt,
        workingDir,
        status: 'pending',
        output: null,
        durationMs: null,
        createdAt: Date.now() + seq,
        updatedAt: Date.now() + seq,
      };
      tasks.set(id, task);
      return task;
    },

    getTask(id) {
      return tasks.get(id) || null;
    },

    updateTask(id, updates) {
      const task = tasks.get(id);
      if (!task) return null;
      Object.assign(task, updates, { updatedAt: Date.now() });
      return task;
    },

    listTasks(filters = {}) {
      let list = [...tasks.values()];
      if (filters.status) {
        list = list.filter((t) => t.status === filters.status);
      }
      if (filters.machineId) {
        list = list.filter((t) => t.machineId === filters.machineId);
      }
      // Return DESC by createdAt (matches real registry behavior)
      list.sort((a, b) => b.createdAt - a.createdAt);
      return list;
    },

    countTasks(filters = {}) {
      return this.listTasks(filters).length;
    },

    save() { /* no-op for mock */ },
  };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe('TaskQueue', () => {
  let registry;
  let workers;
  let dispatched;
  let dispatchFn;

  beforeEach(() => {
    registry = createMockRegistry();
    workers = new Map();
    dispatched = [];
    dispatchFn = (task, worker, machineId) => {
      dispatched.push({ task, machineId });
    };
  });

  it('should enqueue a task with status "queued"', () => {
    const queue = createTaskQueue(registry, workers, dispatchFn);
    const task = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    const result = queue.enqueue(task);

    assert.equal(result.status, 'queued');
    assert.equal(result.queuePosition, 1);
  });

  it('should reject enqueue when queue is full', () => {
    const queue = createTaskQueue(registry, workers, dispatchFn, { maxQueueSize: 2 });

    const t1 = registry.createTask({ machineId: 'machine-1', prompt: 'task 1' });
    const t2 = registry.createTask({ machineId: 'machine-1', prompt: 'task 2' });
    queue.enqueue(t1);
    queue.enqueue(t2);

    const t3 = registry.createTask({ machineId: 'machine-1', prompt: 'task 3' });
    assert.throws(() => queue.enqueue(t3), /Queue is full/);
  });

  it('should drain queued tasks to idle workers', () => {
    workers.set('machine-1', { ws: {}, status: 'idle', agentName: 'Bot1' });

    const queue = createTaskQueue(registry, workers, dispatchFn);
    const task = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    registry.updateTask(task.id, { status: 'queued' });
    registry.save();

    const count = queue.drain();
    assert.equal(count, 1);
    assert.equal(dispatched.length, 1);
    assert.equal(dispatched[0].machineId, 'machine-1');
  });

  it('should not drain when all workers are busy', () => {
    workers.set('machine-1', { ws: {}, status: 'busy', agentName: 'Bot1' });

    const queue = createTaskQueue(registry, workers, dispatchFn);
    const task = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    registry.updateTask(task.id, { status: 'queued' });
    registry.save();

    const count = queue.drain();
    assert.equal(count, 0);
    assert.equal(dispatched.length, 0);
  });

  it('should drain tasks in FIFO order', () => {
    workers.set('machine-1', { ws: {}, status: 'idle', agentName: 'Bot1' });
    workers.set('machine-2', { ws: {}, status: 'idle', agentName: 'Bot2' });

    const queue = createTaskQueue(registry, workers, dispatchFn);
    const t1 = registry.createTask({ machineId: 'any', prompt: 'first' });
    const t2 = registry.createTask({ machineId: 'any', prompt: 'second' });
    registry.updateTask(t1.id, { status: 'queued' });
    registry.updateTask(t2.id, { status: 'queued' });
    registry.save();

    queue.drain();
    assert.equal(dispatched.length, 2);
    // First task dispatched first
    assert.equal(dispatched[0].task.prompt, 'first');
    assert.equal(dispatched[1].task.prompt, 'second');
  });

  it('should fall back to any idle worker when target is busy', () => {
    workers.set('machine-1', { ws: {}, status: 'busy', agentName: 'Bot1' });
    workers.set('machine-2', { ws: {}, status: 'idle', agentName: 'Bot2' });

    const queue = createTaskQueue(registry, workers, dispatchFn);
    const task = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    registry.updateTask(task.id, { status: 'queued' });
    registry.save();

    const count = queue.drain();
    assert.equal(count, 1);
    assert.equal(dispatched[0].machineId, 'machine-2');
  });

  it('should report correct queue length', () => {
    const queue = createTaskQueue(registry, workers, dispatchFn);

    assert.equal(queue.getQueueLength(), 0);

    const t1 = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    registry.updateTask(t1.id, { status: 'queued' });

    assert.equal(queue.getQueueLength(), 1);
  });

  it('should return queued tasks in chronological order', () => {
    const queue = createTaskQueue(registry, workers, dispatchFn);
    const t1 = registry.createTask({ machineId: 'machine-1', prompt: 'first' });
    const t2 = registry.createTask({ machineId: 'machine-1', prompt: 'second' });
    registry.updateTask(t1.id, { status: 'queued' });
    registry.updateTask(t2.id, { status: 'queued' });

    const queued = queue.getQueuedTasks();
    assert.equal(queued.length, 2);
    assert.equal(queued[0].prompt, 'first');
    assert.equal(queued[1].prompt, 'second');
  });

  it('should return correct queue position', () => {
    const queue = createTaskQueue(registry, workers, dispatchFn);
    const t1 = registry.createTask({ machineId: 'machine-1', prompt: 'first' });
    const t2 = registry.createTask({ machineId: 'machine-1', prompt: 'second' });
    registry.updateTask(t1.id, { status: 'queued' });
    registry.updateTask(t2.id, { status: 'queued' });

    assert.equal(queue.getQueuePosition(t1.id), 1);
    assert.equal(queue.getQueuePosition(t2.id), 2);
  });

  it('should return -1 for position of non-queued task', () => {
    const queue = createTaskQueue(registry, workers, dispatchFn);
    assert.equal(queue.getQueuePosition('nonexistent'), -1);
  });

  it('should mark worker busy after dispatching', () => {
    const worker = { ws: {}, status: 'idle', agentName: 'Bot1' };
    workers.set('machine-1', worker);

    const queue = createTaskQueue(registry, workers, dispatchFn);
    const task = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    registry.updateTask(task.id, { status: 'queued' });
    registry.save();

    queue.drain();
    assert.equal(worker.status, 'busy');
  });

  it('onWorkerIdle should trigger drain', () => {
    const worker = { ws: {}, status: 'idle', agentName: 'Bot1' };
    workers.set('machine-1', worker);

    const queue = createTaskQueue(registry, workers, dispatchFn);
    const task = registry.createTask({ machineId: 'machine-1', prompt: 'test' });
    registry.updateTask(task.id, { status: 'queued' });
    registry.save();

    queue.onWorkerIdle('machine-1');
    assert.equal(dispatched.length, 1);
  });

  it('should resolve agent name to machineId during drain', () => {
    workers.set('machine-1', { ws: {}, status: 'idle', agentName: 'CodeBot' });

    const queue = createTaskQueue(registry, workers, dispatchFn);
    // Task recorded with agent name as machineId (simulating how relay stores it)
    const task = registry.createTask({ machineId: 'codebot', prompt: 'test' });
    registry.updateTask(task.id, { status: 'queued' });
    registry.save();

    const count = queue.drain();
    assert.equal(count, 1);
    assert.equal(dispatched[0].machineId, 'machine-1');
  });
});
