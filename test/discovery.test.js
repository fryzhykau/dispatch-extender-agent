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

  it('should broadcast a signed JSON message with type "dispatch-relay"', async () => {
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
          const envelope = JSON.parse(msg.toString());
          // Signed format: { payload, ts, hmac }
          const data = JSON.parse(envelope.payload);
          resolve({ envelope, data });
        } catch (err) {
          reject(err);
        }
      });

      listener.bind(TEST_BROADCAST_PORT, () => {
        handle = startBroadcast(TEST_BROADCAST_PORT, 9090, 500, 'test-secret');
      });
    });

    assert.equal(received.data.type, 'dispatch-relay');
    assert.equal(received.data.port, 9090);
    assert.equal(typeof received.data.host, 'string');
    assert.ok(received.data.host.length > 0);
    assert.equal(typeof received.data.version, 'string');
    assert.ok(received.data.version.length > 0, 'version should be non-empty');
    // Verify signed envelope has required fields
    assert.equal(typeof received.envelope.ts, 'string');
    assert.equal(typeof received.envelope.hmac, 'string');
    assert.ok(received.envelope.hmac.length > 0);
  });

  it('should broadcast a host IP that is not a virtual adapter address', async () => {
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
          const envelope = JSON.parse(msg.toString());
          resolve(JSON.parse(envelope.payload));
        } catch (err) {
          reject(err);
        }
      });

      listener.bind(TEST_BROADCAST_PORT + 2, () => {
        handle = startBroadcast(TEST_BROADCAST_PORT + 2, 7070, 500);
      });
    });

    const host = received.host;

    // The broadcast host should not be a link-local address
    assert.ok(!host.startsWith('169.254.'),
      `Expected non-link-local IP, got ${host}`);

    // Should not be a common Docker/WSL virtual prefix (172.17.x, 172.18.x, etc.)
    const virtualPrefixes = [
      '172.17.', '172.18.', '172.19.', '172.20.',
      '172.21.', '172.22.', '172.23.', '172.24.',
      '172.25.', '172.26.', '172.27.', '172.28.',
      '172.29.', '172.30.', '172.31.',
    ];
    const isVirtualPrefix = virtualPrefixes.some((p) => host.startsWith(p));

    // On machines with only virtual adapters this might still match,
    // so we only assert when the host is not 127.0.0.1 (the fallback)
    if (host !== '127.0.0.1') {
      assert.ok(!isVirtualPrefix,
        `Expected non-virtual IP prefix, got ${host}`);
    }
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
