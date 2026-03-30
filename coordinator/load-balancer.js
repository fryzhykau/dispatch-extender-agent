/**
 * coordinator/load-balancer.js
 *
 * Phase 2 — Load balancing across identical/similar worker machines.
 * Provides multiple strategies for selecting the best machine for a subtask.
 */

const DEFAULT_RELAY_URL = 'http://localhost:7070';

// ---------------------------------------------------------------------------
// Strategies
// ---------------------------------------------------------------------------

/**
 * Round-robin: rotate through idle machines in order.
 */
function createRoundRobin() {
  let index = 0;

  return {
    name: 'round-robin',
    select(machines, _taskHistory) {
      const idle = machines.filter((m) => m.status === 'idle');
      if (idle.length === 0) return null;
      if (idle.length === 1) return idle[0];

      const pick = idle[index % idle.length];
      index = (index + 1) % idle.length;
      return pick;
    },
  };
}

/**
 * Least-busy: pick the idle machine that completed the fewest tasks in the last hour.
 */
function createLeastBusy() {
  const fallback = createRoundRobin();

  return {
    name: 'least-busy',
    select(machines, taskHistory) {
      const idle = machines.filter((m) => m.status === 'idle');
      if (idle.length === 0) return null;
      if (idle.length === 1) return idle[0];

      // No history — fall back to round-robin
      if (!taskHistory || taskHistory.length === 0) {
        return fallback.select(machines, taskHistory);
      }

      const oneHourAgo = Date.now() - 60 * 60 * 1000;
      const recentTasks = taskHistory.filter(
        (t) => t.createdAt && t.createdAt >= oneHourAgo
      );

      // Count completed tasks per machine in the last hour
      const countMap = new Map();
      for (const t of recentTasks) {
        countMap.set(t.machineId, (countMap.get(t.machineId) || 0) + 1);
      }

      // Pick the idle machine with the lowest count
      let best = null;
      let bestCount = Infinity;
      for (const m of idle) {
        const count = countMap.get(m.machineId) || 0;
        if (count < bestCount) {
          bestCount = count;
          best = m;
        }
      }

      return best;
    },
  };
}

/**
 * Fastest: pick the idle machine with the lowest average durationMs
 * across its last 10 completed tasks.
 */
function createFastest() {
  const fallback = createRoundRobin();

  return {
    name: 'fastest',
    select(machines, taskHistory) {
      const idle = machines.filter((m) => m.status === 'idle');
      if (idle.length === 0) return null;
      if (idle.length === 1) return idle[0];

      if (!taskHistory || taskHistory.length === 0) {
        return fallback.select(machines, taskHistory);
      }

      // Group completed tasks by machine, keep last 10 with a durationMs
      const byMachine = new Map();
      for (const t of taskHistory) {
        if (t.status === 'done' && t.durationMs != null) {
          if (!byMachine.has(t.machineId)) {
            byMachine.set(t.machineId, []);
          }
          byMachine.get(t.machineId).push(t.durationMs);
        }
      }

      // Compute averages (last 10 tasks per machine)
      const avgMap = new Map();
      const allAverages = [];
      for (const [machineId, durations] of byMachine) {
        const last10 = durations.slice(-10);
        const avg = last10.reduce((a, b) => a + b, 0) / last10.length;
        avgMap.set(machineId, avg);
        allAverages.push(avg);
      }

      // Neutral score for machines with no history = median of all averages
      let neutralScore = 0;
      if (allAverages.length > 0) {
        const sorted = [...allAverages].sort((a, b) => a - b);
        const mid = Math.floor(sorted.length / 2);
        neutralScore =
          sorted.length % 2 === 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid];
      }

      // Pick idle machine with lowest average
      let best = null;
      let bestAvg = Infinity;
      for (const m of idle) {
        const avg = avgMap.get(m.machineId) ?? neutralScore;
        if (avg < bestAvg) {
          bestAvg = avg;
          best = m;
        }
      }

      return best;
    },
  };
}

/**
 * Random: randomly pick from idle machines.
 */
function createRandom() {
  return {
    name: 'random',
    select(machines, _taskHistory) {
      const idle = machines.filter((m) => m.status === 'idle');
      if (idle.length === 0) return null;
      if (idle.length === 1) return idle[0];

      return idle[Math.floor(Math.random() * idle.length)];
    },
  };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

const STRATEGIES = {
  'round-robin': createRoundRobin,
  'least-busy': createLeastBusy,
  fastest: createFastest,
  random: createRandom,
};

/**
 * Create a load balancer with the given strategy.
 * @param {'round-robin'|'least-busy'|'fastest'|'random'} [strategy='least-busy']
 * @returns {{ select(machines: object[], taskHistory: object[]): object|null }}
 */
export function createLoadBalancer(strategy = 'least-busy') {
  const factory = STRATEGIES[strategy];
  if (!factory) {
    throw new Error(
      `Unknown load balancing strategy "${strategy}". ` +
        `Available: ${Object.keys(STRATEGIES).join(', ')}`
    );
  }
  return factory();
}

/**
 * Fetch current machine status and recent task history from the relay,
 * then compute per-machine statistics.
 *
 * @param {string} [relayUrl]
 * @returns {Promise<Array<{ machineId: string, status: string, completedTasks1h: number, avgDurationMs: number|null, errorRate: number, lastTaskAt: string|null }>>}
 */
export async function getStats(relayUrl = DEFAULT_RELAY_URL, token = '') {
  // Fetch machines and stats in parallel
  const authHeaders = { 'Authorization': `Bearer ${token}` };
  const [machinesRes, statsRes] = await Promise.all([
    fetch(`${relayUrl}/status`, { headers: authHeaders }),
    fetch(`${relayUrl}/stats`, { headers: authHeaders }),
  ]);

  if (!machinesRes.ok) {
    throw new Error(`GET /status failed: ${machinesRes.status} ${machinesRes.statusText}`);
  }
  if (!statsRes.ok) {
    throw new Error(`GET /stats failed: ${statsRes.status} ${statsRes.statusText}`);
  }

  const machines = await machinesRes.json();
  const statsData = await statsRes.json();

  // Build a lookup from the stats endpoint
  const statsMap = new Map();
  for (const s of statsData) {
    statsMap.set(s.machineId, s);
  }

  // Merge machine status with stats
  return machines.map((m) => {
    const s = statsMap.get(m.machineId) || {};
    return {
      machineId: m.machineId,
      status: m.status,
      completedTasks1h: s.completedTasks1h ?? 0,
      avgDurationMs: s.avgDurationMs ?? null,
      errorRate: s.errorRate ?? 0,
      lastTaskAt: s.lastTaskAt ?? null,
    };
  });
}
