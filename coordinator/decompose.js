/**
 * coordinator/decompose.js
 *
 * Decomposes a high-level task into subtasks and dispatches them
 * to worker machines via the relay HTTP API.
 */

import { createLoadBalancer, getStats } from './load-balancer.js';

const DEFAULT_RELAY_URL = 'http://localhost:7070';

/**
 * Fetch all connected machines from the relay and return only the idle ones.
 * @param {string} [relayUrl]
 * @returns {Promise<Array<{ machineId: string, status: string, workingDir: string }>>}
 */
export async function getAvailableMachines(relayUrl = DEFAULT_RELAY_URL, token = '') {
  const res = await fetch(`${relayUrl}/status`, {
    headers: { 'Authorization': `Bearer ${token}` },
  });
  if (!res.ok) {
    throw new Error(`GET /status failed: ${res.status} ${res.statusText}`);
  }
  const machines = await res.json();
  return machines.filter((m) => m.status === 'idle');
}

/**
 * Submit a task to a specific machine via the relay.
 * @param {string} relayUrl
 * @param {{ machineId: string, prompt: string, workingDir: string }} payload
 * @returns {Promise<object>} The created task object (includes `id`, `status`, etc.)
 */
export async function submitTask(relayUrl = DEFAULT_RELAY_URL, { machineId, prompt, workingDir, agentName, pin }, token = '') {
  const payload = { machineId, prompt, workingDir };
  if (agentName) payload.agentName = agentName;
  if (pin) payload.pin = pin;
  const res = await fetch(`${relayUrl}/task`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`POST /task failed: ${res.status} ${res.statusText} — ${body}`);
  }
  return res.json();
}

/**
 * Poll a task until it reaches a terminal status or the timeout expires.
 * @param {string} relayUrl
 * @param {string} taskId
 * @param {{ interval?: number, timeout?: number }} opts
 * @returns {Promise<object>} The final task object
 */
export async function pollTask(relayUrl = DEFAULT_RELAY_URL, taskId, { interval = 10_000, timeout = 300_000 } = {}, token = '') {
  const TERMINAL = new Set(['done', 'error', 'timeout']);
  const deadline = Date.now() + timeout;

  while (true) {
    const res = await fetch(`${relayUrl}/task/${taskId}`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    if (!res.ok) {
      throw new Error(`GET /task/${taskId} failed: ${res.status} ${res.statusText}`);
    }

    const task = await res.json();

    if (TERMINAL.has(task.status)) {
      return task;
    }

    if (Date.now() >= deadline) {
      throw new Error(`Polling timed out after ${timeout}ms for task ${taskId}`);
    }

    await new Promise((resolve) => setTimeout(resolve, interval));
  }
}

/**
 * Heuristic v1 decomposer.
 *
 * - One machine  → send the whole task to it.
 * - N machines   → split the task description by sentences and assign round-robin.
 *
 * @param {string} taskDescription  Natural-language task
 * @param {Array<{ machineId: string, workingDir: string }>} machines
 * @param {{ select(machines: object[], taskHistory: object[]): object|null }|null} [balancer]
 *   Optional load balancer — when provided, machines are ordered by balancer preference.
 * @param {object[]} [taskHistory]  Recent tasks from the registry (used by the balancer).
 * @returns {Array<{ machineId: string, prompt: string, workingDir: string }>}
 */
export function decompose(taskDescription, machines, balancer = null, taskHistory = []) {
  if (!machines || machines.length === 0) {
    throw new Error('No available machines to decompose the task onto.');
  }

  // Prefer agents whose capabilities match keywords in the task description
  const taskLower = taskDescription.toLowerCase();
  const capabilityKeywords = ['code', 'refactor', 'review', 'debug', 'research', 'test', 'deploy', 'docs', 'design'];
  const matchedKeywords = capabilityKeywords.filter((kw) => taskLower.includes(kw));

  if (matchedKeywords.length > 0 && machines.length > 1) {
    // Score each machine by how many of its capabilities match the task keywords
    const scored = machines.map((m) => {
      const caps = (m.agentCapabilities || []).map((c) => c.toLowerCase());
      const score = matchedKeywords.filter((kw) => caps.includes(kw)).length;
      return { machine: m, score };
    });
    scored.sort((a, b) => b.score - a.score);
    // If there's a clear winner with capabilities, put it first
    if (scored[0].score > 0) {
      machines = scored.map((s) => s.machine);
    }
  }

  // When a balancer is provided, re-order machines by preference.
  // The balancer picks one machine at a time; we build a sorted list.
  if (balancer && machines.length > 1) {
    const ordered = [];
    const remaining = [...machines];
    while (remaining.length > 0) {
      const pick = balancer.select(remaining, taskHistory);
      if (!pick) break;
      ordered.push(pick);
      const idx = remaining.findIndex((m) => m.machineId === pick.machineId);
      if (idx !== -1) remaining.splice(idx, 1);
    }
    // Append any that the balancer didn't pick (e.g. busy ones filtered out)
    for (const m of remaining) {
      if (!ordered.find((o) => o.machineId === m.machineId)) {
        ordered.push(m);
      }
    }
    machines = ordered;
  }

  // Single machine — send the whole task
  if (machines.length === 1) {
    const m = machines[0];
    const target = m.agentName ? { agentName: m.agentName } : { machineId: m.machineId };
    return [
      {
        ...target,
        machineId: m.machineId,
        prompt: [
          'You are executing the following task as the sole worker in a multi-machine dispatch system.',
          '',
          `Task: ${taskDescription}`,
        ].join('\n'),
        workingDir: m.workingDir || m.defaultWorkingDir || '.',
      },
    ];
  }

  // Multiple machines — split by sentences, assign round-robin
  const sentences = taskDescription
    .split(/(?<=[.!?])\s+/)
    .map((s) => s.trim())
    .filter(Boolean);

  // If we can't split meaningfully, duplicate the whole task to each machine
  if (sentences.length <= 1) {
    return machines.map((m, i) => ({
      machineId: m.machineId,
      ...(m.agentName ? { agentName: m.agentName } : {}),
      prompt: [
        `You are worker ${i + 1} of ${machines.length} in a multi-machine dispatch system.`,
        `Each worker is handling a portion of the same overall task.`,
        '',
        `Overall task: ${taskDescription}`,
        '',
        `Focus on the aspects most relevant to your working directory (${m.workingDir || m.defaultWorkingDir || '.'}).`,
      ].join('\n'),
      workingDir: m.workingDir || m.defaultWorkingDir || '.',
    }));
  }

  // Distribute sentences round-robin across machines
  const buckets = machines.map(() => []);
  for (let i = 0; i < sentences.length; i++) {
    buckets[i % machines.length].push(sentences[i]);
  }

  return machines.map((m, i) => ({
    machineId: m.machineId,
    ...(m.agentName ? { agentName: m.agentName } : {}),
    prompt: [
      `You are worker ${i + 1} of ${machines.length} in a multi-machine dispatch system.`,
      `This is your portion of a larger task. The overall task is:`,
      `"${taskDescription}"`,
      '',
      `Your assigned subtask:`,
      buckets[i].join(' '),
    ].join('\n'),
    workingDir: m.workingDir || m.defaultWorkingDir || '.',
  }));
}

/**
 * Main entry point: decompose a task, dispatch subtasks in parallel,
 * poll for results, retry failures once, and return an aggregated summary.
 *
 * @param {string} taskDescription
 * @param {string} [relayUrl]
 * @param {string} [strategy='least-busy']  Load balancing strategy.
 * @returns {Promise<{ subtasks: object[], summary: string }>}
 */
export async function orchestrate(taskDescription, relayUrl = DEFAULT_RELAY_URL, strategy = 'least-busy', token = '', pin = '') {
  // 1. Discover idle machines
  console.log('[orchestrate] Fetching available machines...');
  const machines = await getAvailableMachines(relayUrl, token);

  if (machines.length === 0) {
    throw new Error('No idle machines available. Cannot dispatch task.');
  }
  console.log(`[orchestrate] ${machines.length} idle machine(s): ${machines.map((m) => m.agentName ? `${m.agentName} (${m.machineId})` : m.machineId).join(', ')}`);

  // 2. Initialise load balancer and fetch recent task history
  const balancer = createLoadBalancer(strategy);
  console.log(`[orchestrate] Load balancing strategy: ${balancer.name}`);

  let taskHistory = [];
  try {
    const statsRes = await fetch(`${relayUrl}/stats`, {
      headers: { 'Authorization': `Bearer ${token}` },
    });
    if (statsRes.ok) {
      // The /stats endpoint returns per-machine summaries; we also need raw
      // task history for the balancer.  Fetch recent tasks from the relay.
      const historyRes = await fetch(`${relayUrl}/tasks`, {
        headers: { 'Authorization': `Bearer ${token}` },
      }).catch(() => null);
      if (historyRes && historyRes.ok) {
        const body = await historyRes.json();
        taskHistory = body.tasks || body;
      }
    }
  } catch {
    // Non-fatal — balancer will fall back to round-robin behaviour
    console.log('[orchestrate] Could not fetch task history; balancer will use fallback.');
  }

  // 3. Decompose
  const subtaskDefs = decompose(taskDescription, machines, balancer, taskHistory);
  console.log(`[orchestrate] Decomposed into ${subtaskDefs.length} subtask(s).`);

  // 4. Submit all subtasks in parallel
  const submitted = await Promise.all(
    subtaskDefs.map(async (def) => {
      const targetLabel = def.agentName ? `${def.agentName} (${def.machineId})` : def.machineId;
      console.log(`[orchestrate] Submitting subtask to ${targetLabel}...`);
      const defWithPin = pin ? { ...def, pin } : def;
      const task = await submitTask(relayUrl, defWithPin, token);
      console.log(`[orchestrate] Subtask ${task.id} submitted to ${targetLabel}.`);
      return { ...task, _def: def };
    })
  );

  // 4. Poll all subtasks in parallel
  console.log('[orchestrate] Polling subtasks for completion...');
  const results = await Promise.allSettled(
    submitted.map((t) => pollTask(relayUrl, t.id, {}, token))
  );

  // 5. Collect completed tasks, retry errors once on a different machine
  const finalResults = [];

  for (let i = 0; i < results.length; i++) {
    const result = results[i];
    const original = submitted[i];

    if (result.status === 'fulfilled' && result.value.status === 'done') {
      finalResults.push(result.value);
      console.log(`[orchestrate] Subtask ${original.id} completed on ${original.machineId}.`);
      continue;
    }

    // Error path — attempt one retry on a different machine
    const failedMachineId = original.machineId;
    const errorInfo = result.status === 'rejected'
      ? result.reason?.message
      : result.value?.output || result.value?.status;
    console.log(`[orchestrate] Subtask ${original.id} failed on ${failedMachineId}: ${errorInfo}. Retrying...`);

    // Re-fetch available machines to find an alternative
    let retryMachines;
    try {
      retryMachines = await getAvailableMachines(relayUrl, token);
    } catch {
      retryMachines = [];
    }

    const altMachine = retryMachines.find((m) => m.machineId !== failedMachineId) || retryMachines[0];

    if (!altMachine) {
      console.log(`[orchestrate] No machines available for retry of subtask ${original.id}. Recording as failed.`);
      finalResults.push(
        result.status === 'fulfilled'
          ? result.value
          : { id: original.id, status: 'error', output: errorInfo, machineId: failedMachineId }
      );
      continue;
    }

    try {
      console.log(`[orchestrate] Retrying subtask on ${altMachine.machineId}...`);
      const retryDef = { ...original._def, machineId: altMachine.machineId, workingDir: altMachine.workingDir || altMachine.defaultWorkingDir || original._def.workingDir };
      if (pin) retryDef.pin = pin;
      const retryTask = await submitTask(relayUrl, retryDef, token);
      const retryResult = await pollTask(relayUrl, retryTask.id, {}, token);
      finalResults.push(retryResult);
      console.log(`[orchestrate] Retry subtask ${retryTask.id} finished with status: ${retryResult.status}`);
    } catch (retryErr) {
      console.log(`[orchestrate] Retry also failed: ${retryErr.message}`);
      finalResults.push(
        result.status === 'fulfilled'
          ? result.value
          : { id: original.id, status: 'error', output: retryErr.message, machineId: failedMachineId }
      );
    }
  }

  // 6. Aggregate results into a summary (under 300 words per spec)
  const summary = buildSummary(taskDescription, finalResults);
  console.log('[orchestrate] Done. Summary generated.');

  return { subtasks: finalResults, summary };
}

/**
 * Build a concise summary (under 300 words) from all subtask results.
 * @param {string} taskDescription
 * @param {object[]} results
 * @returns {string}
 */
function buildSummary(taskDescription, results) {
  const succeeded = results.filter((r) => r.status === 'done');
  const failed = results.filter((r) => r.status !== 'done');

  const lines = [`Task: ${taskDescription}`, ''];

  if (succeeded.length > 0) {
    lines.push(`Completed ${succeeded.length} of ${results.length} subtask(s).`);
    lines.push('');
    for (const r of succeeded) {
      const output = (r.output || '').trim();
      // Truncate individual outputs to keep summary concise
      const truncated = output.length > 500 ? output.slice(0, 497) + '...' : output;
      lines.push(`[${r.machineId}] ${truncated}`);
    }
  }

  if (failed.length > 0) {
    lines.push('');
    lines.push(`${failed.length} subtask(s) failed:`);
    for (const r of failed) {
      lines.push(`[${r.machineId}] status=${r.status}: ${(r.output || 'no output').slice(0, 200)}`);
    }
  }

  // Enforce the 300-word limit
  let summary = lines.join('\n');
  const words = summary.split(/\s+/);
  if (words.length > 300) {
    summary = words.slice(0, 295).join(' ') + ' ... [truncated]';
  }

  return summary;
}
