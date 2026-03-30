/**
 * test/discovery.test.js
 *
 * Tests for the UDP discovery module (relay/discovery.js).
 */

import { describe, it, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import dgram from 'node:dgram';
import { startBroadcast } from '../relay/discovery.js';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TEST_BROADCAST_PORT = 17071; // Use a high port to avoid conflicts
let handle = null;

afterEach(() => {
  if (handle) {
    handle.stop();
    handle = null;
  }
});

describe('startBroadcast', () => {
  it('should return an object with a stop method', () => {
    handle = startBroadcast(TEST_BROADCAST_PORT, 7070, 60000);
    assert.equal(typeof handle.stop, 'function');
  });

  it('should broadcast a JSON message with type "dispatch-relay"', async () => {
    const received = await new Promise((resolve, reject) => {
      const listener = dgram.createSocket({ type: 'udp4', reuseAddr: true });

      const timeout = setTimeout(() => {
        listener.close();
        reject(new Error('Timeout waiting for broadcast'));
      }, 10000);

      listener.on('message', (msg) => {
        clearTimeout(timeout);
        listener.close();
        try {
          resolve(JSON.parse(msg.toString()));
        } catch (err) {
          reject(err);
        }
      });

      listener.bind(TEST_BROADCAST_PORT, () => {
        // Start broadcasting after listener is ready
        handle = startBroadcast(TEST_BROADCAST_PORT, 9090, 500);
      });
    });

    assert.equal(received.type, 'dispatch-relay');
    assert.equal(received.port, 9090);
    assert.equal(typeof received.host, 'string');
    assert.ok(received.host.length > 0);
    assert.equal(received.version, '1.0.0');
  });

  it('should stop broadcasting after stop() is called', async () => {
    handle = startBroadcast(TEST_BROADCAST_PORT + 1, 7070, 200);

    // Wait for at least one broadcast
    await new Promise((r) => setTimeout(r, 500));

    handle.stop();
    handle = null;

    // Listen briefly — should receive nothing
    const gotMessage = await new Promise((resolve) => {
      const listener = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      const timeout = setTimeout(() => {
        listener.close();
        resolve(false);
      }, 1000);

      listener.on('message', () => {
        clearTimeout(timeout);
        listener.close();
        resolve(true);
      });

      listener.bind(TEST_BROADCAST_PORT + 1);
    });

    assert.equal(gotMessage, false, 'Should not receive broadcasts after stop()');
  });
});
