import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getDataDir } from '../lib/data-dir.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const DEFAULT_LOG_DIR = getDataDir(path.resolve(__dirname, '..'));
const LOG_FILENAME = 'audit.log';

/**
 * Initialize the audit logger.
 * Ensures the log directory exists and returns a logger object.
 * @param {string} [logDir] — directory for the audit log file (default: ../data)
 * @returns {{ log, warn, error, security, getLogPath }}
 */
export function initAudit(logDir) {
  const dir = logDir || DEFAULT_LOG_DIR;
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const logPath = path.join(dir, LOG_FILENAME);

  function writeEntry(level, event, details) {
    const entry = {
      timestamp: new Date().toISOString(),
      level,
      event,
      details: details || {},
    };
    const line = JSON.stringify(entry) + '\n';

    // Append to file
    fs.appendFileSync(logPath, line, 'utf-8');

    // Console output
    const tag = level === 'error' ? '\x1b[31m[audit]\x1b[0m'
      : level === 'warn' ? '\x1b[33m[audit]\x1b[0m'
      : '[audit]';
    console.log(`${tag} [${level}] ${event}`, JSON.stringify(details));
  }

  return {
    log(event, details) {
      writeEntry('info', event, details);
    },
    warn(event, details) {
      writeEntry('warn', event, details);
    },
    error(event, details) {
      writeEntry('error', event, details);
    },
    security(event, details) {
      writeEntry('error', `SECURITY: ${event}`, details);
    },
    getLogPath() {
      return logPath;
    },
  };
}
