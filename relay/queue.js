/**
 * Persistent task queue for the dispatch orchestrator.
 *
 * Tasks that cannot be dispatched immediately (machine busy or disconnected)
 * are stored with status "queued" in the existing task registry and drained
 * automatically whenever a worker becomes idle.
 */

/**
 * Create a task queue backed by the existing task registry.
 *
 * @param {object}   registry   - Task registry returned by initRegistry()
 * @param {Map}      workers    - Live workers map (machineId -> worker info)
 * @param {Function} dispatchFn - (task, worker) => void — sends the task payload over WS
 * @param {object}   [options]
 * @param {number}   [options.maxQueueSize=100] - Maximum number of queued tasks
 * @returns {object} Queue interface
 */
export function createTaskQueue(registry, workers, dispatchFn, options = {}) {
  const maxQueueSize = options.maxQueueSize ?? 100;

  const queue = {
    /**
     * Enqueue a task.  Sets its status to "queued" and attempts an
     * immediate drain so it may be dispatched right away if a worker is free.
     *
     * @param {object} task - Task object (already created in registry with status "pending")
     * @returns {object} Updated task with status "queued" and its queue position
     */
    enqueue(task) {
      const currentLength = queue.getQueueLength();
      if (currentLength >= maxQueueSize) {
        throw new Error(`Queue is full (max ${maxQueueSize})`);
      }

      registry.updateTask(task.id, { status: 'queued' });
      registry.save();

      const position = queue.getQueuePosition(task.id);

      // Attempt to drain immediately (non-blocking)
      Promise.resolve().then(() => queue.drain());

      return { ...task, status: 'queued', queuePosition: position };
    },

    /**
     * Drain the queue — dispatch as many queued tasks as possible to idle
     * workers.  Tasks are processed in FIFO order (createdAt ASC).
     *
     * @returns {number} Number of tasks dispatched during this drain cycle
     */
    drain() {
      const queued = registry.listTasks({ status: 'queued' });
      // listTasks returns DESC by default; we need ASC (FIFO)
      queued.reverse();

      let dispatched = 0;

      for (const task of queued) {
        // Try the originally-requested machine first
        let targetWorker = null;
        let targetMachineId = null;

        if (task.machineId && task.machineId !== 'any') {
          // Check if machineId is actually an agent name (not found as a direct key)
          if (workers.has(task.machineId)) {
            const w = workers.get(task.machineId);
            if (w && w.status === 'idle') {
              targetWorker = w;
              targetMachineId = task.machineId;
            }
          } else {
            // Try resolving as agent name (case-insensitive)
            const nameLower = task.machineId.toLowerCase();
            for (const [mid, w] of workers) {
              if (w.agentName && w.agentName.toLowerCase() === nameLower && w.status === 'idle') {
                targetWorker = w;
                targetMachineId = mid;
                break;
              }
            }
          }
        }

        // If the specific machine is not available (or machineId is "any"),
        // try any idle worker
        if (!targetWorker) {
          for (const [mid, w] of workers) {
            if (w.status === 'idle') {
              targetWorker = w;
              targetMachineId = mid;
              break;
            }
          }
        }

        if (targetWorker) {
          // Update task status and machineId (may have changed if re-routed)
          registry.updateTask(task.id, { status: 'running' });
          registry.save();

          // Mark the worker busy
          targetWorker.status = 'busy';

          // Dispatch
          dispatchFn(task, targetWorker, targetMachineId);
          dispatched++;
        }
      }

      return dispatched;
    },

    /**
     * Called when a worker finishes a task and becomes idle.
     * Triggers a drain attempt so queued tasks can be picked up.
     *
     * @param {string} machineId
     */
    onWorkerIdle(machineId) {
      queue.drain();
    },

    /**
     * @returns {number} Count of tasks with status "queued"
     */
    getQueueLength() {
      return registry.countTasks({ status: 'queued' });
    },

    /**
     * @returns {Array} All queued tasks ordered by creation time (oldest first)
     */
    getQueuedTasks() {
      const tasks = registry.listTasks({ status: 'queued' });
      // listTasks returns DESC; reverse for chronological order
      tasks.reverse();
      return tasks;
    },

    /**
     * Get the 1-based queue position of a specific task.
     *
     * @param {string} taskId
     * @returns {number} Position in queue (1 = next to be dispatched)
     */
    getQueuePosition(taskId) {
      const tasks = queue.getQueuedTasks();
      const idx = tasks.findIndex((t) => t.id === taskId);
      return idx === -1 ? -1 : idx + 1;
    },
  };

  return queue;
}
