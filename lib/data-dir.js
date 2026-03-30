/**
 * Resolves the writable data directory for the application.
 *
 * When installed to a protected location like "C:\Program Files", the app
 * cannot write data alongside its source files. In that case, we use
 * %APPDATA%\DispatchOrchestrator as the data directory.
 *
 * When running from a normal user directory (dev mode), we use ../data
 * relative to the calling module, which is the project root's data/ folder.
 */

import fs from 'node:fs';
import path from 'node:path';

/**
 * Returns a writable data directory path, creating it if needed.
 * @param {string} fallbackBase — the project root or __dirname of the caller
 * @returns {string} absolute path to the data directory
 */
export function getDataDir(fallbackBase) {
  // Check if we're in a protected directory (Program Files, etc.)
  const normalized = fallbackBase.replace(/\\/g, '/').toLowerCase();
  const isProtected =
    normalized.includes('/program files/') ||
    normalized.includes('/program files (x86)/') ||
    normalized.includes('/windows/');

  let dataDir;
  if (isProtected && process.env.APPDATA) {
    dataDir = path.join(process.env.APPDATA, 'DispatchOrchestrator', 'data');
  } else {
    dataDir = path.resolve(fallbackBase, 'data');
  }

  if (!fs.existsSync(dataDir)) {
    fs.mkdirSync(dataDir, { recursive: true });
  }

  return dataDir;
}
