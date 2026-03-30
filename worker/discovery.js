import dgram from 'node:dgram';

/**
 * Discover a relay on the local network via UDP broadcast.
 * Returns a Promise that resolves with { host, port } when a relay announcement
 * is received, or rejects after the given timeout.
 *
 * @param {number} broadcastPort  UDP port to listen on (default 7071)
 * @param {number} timeout        Timeout in ms (default 15000)
 * @returns {Promise<{ host: string, port: number }>}
 */
export function discoverRelay(broadcastPort = 7071, timeout = 15000) {
  return new Promise((resolve, reject) => {
    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(`Relay discovery timed out after ${timeout}ms`));
    }, timeout);

    socket.on('message', (msg) => {
      try {
        const data = JSON.parse(msg.toString());
        if (data.type === 'dispatch-relay' && data.host && data.port) {
          clearTimeout(timer);
          socket.close();
          resolve({ host: data.host, port: data.port });
        }
      } catch {
        // ignore malformed packets
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
 * @returns {{ stop: () => void }}
 */
export function listenForRelay(callback, broadcastPort = 7071) {
  const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });

  socket.on('message', (msg) => {
    try {
      const data = JSON.parse(msg.toString());
      if (data.type === 'dispatch-relay' && data.host && data.port) {
        callback({ host: data.host, port: data.port });
      }
    } catch {
      // ignore malformed packets
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
