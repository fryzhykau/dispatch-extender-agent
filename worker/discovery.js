import dgram from 'node:dgram';
import crypto from 'node:crypto';

const MAX_DISCOVERY_AGE_MS = 30_000; // reject broadcasts older than 30s

/**
 * Verify and parse a signed discovery message.
 * Returns the inner payload if valid, or null if invalid/unsigned.
 */
function parseDiscoveryMessage(raw, sharedSecret) {
  try {
    const envelope = JSON.parse(raw.toString());

    // Support legacy unsigned format for backward compatibility
    if (envelope.type === 'dispatch-relay' && envelope.host && envelope.port) {
      if (!sharedSecret) return envelope; // no secret configured, accept unsigned
      return null; // secret configured but message unsigned — reject
    }

    // Signed envelope format: { payload, ts, hmac }
    if (!envelope.payload || !envelope.ts || !envelope.hmac) return null;

    // Verify timestamp freshness
    const age = Math.abs(Date.now() - parseInt(envelope.ts, 10));
    if (age > MAX_DISCOVERY_AGE_MS) return null;

    // Verify HMAC
    if (sharedSecret) {
      const expected = crypto.createHmac('sha256', sharedSecret)
        .update(envelope.ts + envelope.payload).digest('hex');
      if (!crypto.timingSafeEqual(Buffer.from(envelope.hmac, 'hex'), Buffer.from(expected, 'hex'))) {
        return null;
      }
    }

    const data = JSON.parse(envelope.payload);
    if (data.type === 'dispatch-relay' && data.host && data.port) {
      return data;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Discover a relay on the local network via UDP broadcast.
 * Returns a Promise that resolves with { host, port } when a relay announcement
 * is received, or rejects after the given timeout.
 *
 * @param {number} broadcastPort  UDP port to listen on (default 7071)
 * @param {number} timeout        Timeout in ms (default 15000)
 * @param {string} sharedSecret   Shared secret for HMAC verification (optional)
 * @returns {Promise<{ host: string, port: number }>}
 */
export function discoverRelay(broadcastPort = 7071, timeout = 15000, sharedSecret = '') {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(`Relay discovery timed out after ${timeout}ms`));
    }, timeout);

    socket.on('message', (msg) => {
      const data = parseDiscoveryMessage(msg, sharedSecret);
      if (data) {
        clearTimeout(timer);
        socket.close();
        resolve({ host: data.host, port: data.port });
      }
    });

    socket.on('error', (err) => {
      clearTimeout(timer);
      socket.close();
      reject(err);
    });

    socket.bind(broadcastPort);
  });
}

/**
 * Continuously listen for relay broadcast announcements.
 * Calls `callback` with { host, port } each time an announcement is received.
 *
 * @param {(relay: { host: string, port: number }) => void} callback
 * @param {number} broadcastPort  UDP port to listen on (default 7071)
 * @param {string} sharedSecret   Shared secret for HMAC verification (optional)
 * @returns {{ stop: () => void }}
 */
export function listenForRelay(callback, broadcastPort = 7071, sharedSecret = '') {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.on('message', (msg) => {
    const data = parseDiscoveryMessage(msg, sharedSecret);
    if (data) {
      callback({ host: data.host, port: data.port });
    }
  });

  socket.on('error', (err) => {
    console.error('[discovery] Listen error:', err.message);
  });

  socket.bind(broadcastPort);

  return {
    stop() {
      socket.close();
    },
  };
}
