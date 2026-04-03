import dgram from 'node:dgram';
import os from 'node:os';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Returns the best non-internal IPv4 address for LAN discovery.
 * Skips virtual adapters (WSL, Hyper-V, VirtualBox, link-local) and
 * prefers physical/Wi-Fi adapters.  Falls back to '127.0.0.1'.
 */
function getLocalIP() {
  const interfaces = os.networkInterfaces();

  // Adapter name patterns that indicate virtual/tunnel interfaces
  const virtualPatterns = [
    /^vEthernet/i, /^WSL/i, /^Hyper-V/i, /^VirtualBox/i,
    /^VMware/i, /^docker/i, /^br-/i, /^veth/i,
  ];

  // IP prefixes used by virtual adapters
  const virtualPrefixes = [
    '172.16.', '172.17.', '172.18.', '172.19.', '172.20.',
    '172.21.', '172.22.', '172.23.', '172.24.', '172.25.',
    '172.26.', '172.27.', '172.28.', '172.29.', '172.30.', '172.31.',
    '169.254.',   // link-local
  ];

  let fallback = null;

  for (const name of Object.keys(interfaces)) {
    const isVirtualName = virtualPatterns.some((p) => p.test(name));

    for (const iface of interfaces[name]) {
      if (iface.family !== 'IPv4' || iface.internal) continue;

      const isVirtualIP = virtualPrefixes.some((p) => iface.address.startsWith(p));

      if (!isVirtualName && !isVirtualIP) {
        return iface.address; // Best match: physical adapter, non-virtual IP
      }
      if (!fallback) {
        fallback = iface.address; // Remember first virtual as fallback
      }
    }
  }

  return fallback || '127.0.0.1';
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
