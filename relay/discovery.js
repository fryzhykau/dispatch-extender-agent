import dgram from 'node:dgram';
import os from 'node:os';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Returns the first non-internal IPv4 address found on this machine.
 * Falls back to '127.0.0.1' if nothing else is available.
 */
function getLocalIP() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        return iface.address;
      }
    }
  }
  return '127.0.0.1';
}

// ---------------------------------------------------------------------------
// Broadcast
// ---------------------------------------------------------------------------

/**
 * Start broadcasting the relay's presence on the local network via UDP.
 *
 * @param {number} broadcastPort  UDP port to broadcast on (default 7071)
 * @param {number} relayPort      The relay's HTTP/WS port (default 7070)
 * @param {number} intervalMs     Milliseconds between broadcasts (default 5000)
 * @returns {{ stop: () => void }}
 */
export function startBroadcast(broadcastPort = 7071, relayPort = 7070, intervalMs = 5000) {
  const socket = dgram.createSocket('udp4');
  let timer = null;

  const localIP = getLocalIP();

  const message = JSON.stringify({
    type: 'dispatch-relay',
    host: localIP,
    port: relayPort,
    version: '1.0.0',
  });

  const buf = Buffer.from(message);

  socket.bind(() => {
    socket.setBroadcast(true);

    timer = setInterval(() => {
      socket.send(buf, 0, buf.length, broadcastPort, '255.255.255.255', (err) => {
        if (err) {
          console.error('[discovery] Broadcast send error:', err.message);
        }
      });
    }, intervalMs);

    console.log(
      `[discovery] Broadcasting on UDP port ${broadcastPort} every ${intervalMs / 1000}s (relay at ${localIP}:${relayPort})`
    );
  });

  return {
    stop() {
      if (timer) {
        clearInterval(timer);
        timer = null;
      }
      socket.close();
    },
  };
}
