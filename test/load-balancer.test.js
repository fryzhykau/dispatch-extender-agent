/**
 * test/load-balancer.test.js
 *
 * Tests for coordinator/load-balancer.js — createLoadBalancer and its strategies.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { createLoadBalancer } from '../coordinator/load-balancer.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeMachine(id, status = 'idle') {
  return { machineId: id, status };
}

function makeTaskHistory(entries) {
  // entries: [{ machineId, status?, durationMs?, createdAt? }]
  return entries.map((e) => ({
    machineId: e.machineId,
    status: e.status || 'done',
    durationMs: e.durationMs ?? 1000,
    createdAt: e.createdAt ?? Date.now(),
  }));
}

// ---------------------------------------------------------------------------
// round-robin strategy
// ---------------------------------------------------------------------------

describe('round-robin strategy', () => {
  it('should return idle machines in order', () => {
    const lb = createLoadBalancer('round-robin');
    const machines = [makeMachine('A'), makeMachine('B'), makeMachine('C')];

    const first = lb.select(machines, []);
    const second = lb.select(machines, []);
    const third = lb.select(machines, []);

    // Should cycle through in order
    assert.equal(first.machineId, 'A');
    assert.equal(second.machineId, 'B');
    assert.equal(third.machineId, 'C');
  });

  it('should skip busy machines', () => {
    const lb = createLoadBalancer('round-robin');
    const machines = [
      makeMachine('A', 'busy'),
      makeMachine('B'),
      makeMachine('C'),
    ];

    const pick = lb.select(machines, []);
    assert.ok(pick);
    assert.notEqual(pick.machineId, 'A');
  });

  it('should wrap around', () => {
    const lb = createLoadBalancer('round-robin');
    const machines = [makeMachine('A'), makeMachine('B')];

    const first = lb.select(machines, []);
    const second = lb.select(machines, []);
    const third = lb.select(machines, []);

    assert.equal(first.machineId, 'A');
    assert.equal(second.machineId, 'B');
    assert.equal(third.machineId, 'A');
  });

  it('should return null when no idle machines', () => {
    const lb = createLoadBalancer('round-robin');
    const machines = [
      makeMachine('A', 'busy'),
      makeMachine('B', 'busy'),
    ];

    const pick = lb.select(machines, []);
    assert.equal(pick, null);
  });
});

// ---------------------------------------------------------------------------
// least-busy strategy
// ---------------------------------------------------------------------------

describe('least-busy strategy', () => {
  it('should prefer machine with fewer recent tasks', () => {
    const lb = createLoadBalancer('least-busy');
    const machines = [makeMachine('A'), makeMachine('B')];

    const now = Date.now();
    const history = makeTaskHistory([
      { machineId: 'A', createdAt: now - 1000 },
      { machineId: 'A', createdAt: now - 2000 },
      { machineId: 'A', createdAt: now - 3000 },
      { machineId: 'B', createdAt: now - 1000 },
    ]);

    const pick = lb.select(machines, history);
    assert.equal(pick.machineId, 'B');
  });

  it('should handle empty task history (fall back to round-robin)', () => {
    const lb = createLoadBalancer('least-busy');
    const machines = [makeMachine('A'), makeMachine('B')];

    const pick = lb.select(machines, []);
    assert.ok(pick);
    assert.ok(['A', 'B'].includes(pick.machineId));
  });

  it('should return null when no idle machines', () => {
    const lb = createLoadBalancer('least-busy');
    const machines = [
      makeMachine('A', 'busy'),
      makeMachine('B', 'busy'),
    ];

    const pick = lb.select(machines, makeTaskHistory([{ machineId: 'A' }]));
    assert.equal(pick, null);
  });
});

// ---------------------------------------------------------------------------
// fastest strategy
// ---------------------------------------------------------------------------

describe('fastest strategy', () => {
  it('should prefer machine with lower average duration', () => {
    const lb = createLoadBalancer('fastest');
    const machines = [makeMachine('A'), makeMachine('B')];

    const history = makeTaskHistory([
      { machineId: 'A', durationMs: 5000, status: 'done' },
      { machineId: 'A', durationMs: 6000, status: 'done' },
      { machineId: 'B', durationMs: 1000, status: 'done' },
      { machineId: 'B', durationMs: 2000, status: 'done' },
    ]);

    const pick = lb.select(machines, history);
    assert.equal(pick.machineId, 'B');
  });

  it('should handle machines with no history', () => {
    const lb = createLoadBalancer('fastest');
    const machines = [makeMachine('A'), makeMachine('B'), makeMachine('C')];

    // Only A has history
    const history = makeTaskHistory([
      { machineId: 'A', durationMs: 2000, status: 'done' },
      { machineId: 'A', durationMs: 3000, status: 'done' },
    ]);

    const pick = lb.select(machines, history);
    // Should pick something (machines without history get the median score)
    assert.ok(pick);
    assert.ok(['A', 'B', 'C'].includes(pick.machineId));
  });
});

// ---------------------------------------------------------------------------
// random strategy
// ---------------------------------------------------------------------------

describe('random strategy', () => {
  it('should return an idle machine', () => {
    const lb = createLoadBalancer('random');
    const machines = [
      makeMachine('A'),
      makeMachine('B', 'busy'),
      makeMachine('C'),
    ];

    const pick = lb.select(machines, []);
    assert.ok(pick);
    assert.notEqual(pick.machineId, 'B');
    assert.ok(['A', 'C'].includes(pick.machineId));
  });

  it('should return null when no idle machines', () => {
    const lb = createLoadBalancer('random');
    const machines = [
      makeMachine('A', 'busy'),
      makeMachine('B', 'busy'),
    ];

    const pick = lb.select(machines, []);
    assert.equal(pick, null);
  });
});

// ---------------------------------------------------------------------------
// Edge cases
// ---------------------------------------------------------------------------

describe('edge cases', () => {
  it('single machine — should always return it if idle', () => {
    for (const strategy of ['round-robin', 'least-busy', 'fastest', 'random']) {
      const lb = createLoadBalancer(strategy);
      const machines = [makeMachine('solo')];
      const pick = lb.select(machines, []);
      assert.ok(pick, `Strategy "${strategy}" should return the single idle machine`);
      assert.equal(pick.machineId, 'solo');
    }
  });

  it('all machines busy — should return null', () => {
    for (const strategy of ['round-robin', 'least-busy', 'fastest', 'random']) {
      const lb = createLoadBalancer(strategy);
      const machines = [
        makeMachine('A', 'busy'),
        makeMachine('B', 'busy'),
        makeMachine('C', 'busy'),
      ];
      const pick = lb.select(machines, []);
      assert.equal(pick, null, `Strategy "${strategy}" should return null for all-busy`);
    }
  });

  it('unknown strategy — should throw', () => {
    assert.throws(
      () => createLoadBalancer('nonexistent-strategy'),
      /Unknown load balancing strategy/
    );
  });
});
