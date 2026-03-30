/**
 * test/config.test.js
 *
 * Tests that relay and worker config files are valid, have required fields,
 * and that placeholder values are present (not accidentally committed secrets).
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

// ---------------------------------------------------------------------------
// Relay config
// ---------------------------------------------------------------------------

describe('relay/config.json', () => {
  const configPath = path.join(ROOT, 'relay', 'config.json');
  let config;

  it('should be valid JSON', () => {
    const raw = fs.readFileSync(configPath, 'utf-8');
    config = JSON.parse(raw);
    assert.ok(config);
  });

  it('should have a numeric port', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.port, 'number');
    assert.ok(config.port >= 1024 && config.port <= 65535);
  });

  it('should have a sharedSecret string', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.sharedSecret, 'string');
    assert.ok(config.sharedSecret.length > 0);
  });

  it('should have placeholder secret (not a real secret in repo)', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.match(config.sharedSecret, /CHANGE-ME/i, 'Shared secret should be a placeholder');
  });

  it('should have a machines array', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.ok(Array.isArray(config.machines));
  });

  it('should have tls config with enabled boolean', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.tls, 'object');
    assert.equal(typeof config.tls.enabled, 'boolean');
  });

  it('should have discovery config', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.discovery, 'object');
    assert.equal(typeof config.discovery.enabled, 'boolean');
  });

  it('should have heartbeat config with valid intervals', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.heartbeat, 'object');
    assert.ok(config.heartbeat.intervalMs > 0);
    assert.ok(config.heartbeat.timeoutMs > 0);
    assert.ok(config.heartbeat.timeoutMs < config.heartbeat.intervalMs,
      'Timeout should be less than interval');
  });

  it('should have rate limiting config', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.rateLimiting, 'object');
    assert.equal(typeof config.rateLimiting.enabled, 'boolean');
  });

  it('should have limits config with valid values', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.limits, 'object');
    assert.ok(config.limits.maxPromptLength > 0);
    assert.ok(config.limits.maxOutputLength > 0);
    assert.ok(config.limits.maxRequestBodyBytes > 0);
  });

  it('should have pin config', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.pin, 'object');
    assert.equal(typeof config.pin.enabled, 'boolean');
    assert.ok(config.pin.maxAttempts > 0);
    assert.ok(config.pin.lockoutMinutes > 0);
  });

  it('should have queue config', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.queue, 'object');
    assert.equal(typeof config.queue.enabled, 'boolean');
  });

  it('should have loadBalancing config with valid strategy', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    const validStrategies = ['round-robin', 'least-busy', 'fastest', 'random'];
    assert.ok(validStrategies.includes(config.loadBalancing.strategy),
      `Strategy "${config.loadBalancing.strategy}" should be one of: ${validStrategies.join(', ')}`);
  });
});

// ---------------------------------------------------------------------------
// Worker config
// ---------------------------------------------------------------------------

describe('worker/worker-config.json', () => {
  const configPath = path.join(ROOT, 'worker', 'worker-config.json');
  let config;

  it('should be valid JSON', () => {
    const raw = fs.readFileSync(configPath, 'utf-8');
    config = JSON.parse(raw);
    assert.ok(config);
  });

  it('should have a machineId string', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.machineId, 'string');
    assert.ok(config.machineId.length > 0);
  });

  it('should have an agentName string', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.agentName, 'string');
    assert.ok(config.agentName.length > 0);
  });

  it('should have agentCapabilities array', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.ok(Array.isArray(config.agentCapabilities));
  });

  it('should have a coordinatorHost string', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.coordinatorHost, 'string');
  });

  it('should have placeholder secret (not a real secret in repo)', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.match(config.sharedSecret, /CHANGE-ME/i, 'Shared secret should be a placeholder');
  });

  it('should have a defaultWorkingDir string', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.defaultWorkingDir, 'string');
    assert.ok(config.defaultWorkingDir.length > 0);
  });

  it('should have allowedDirs array', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.ok(Array.isArray(config.allowedDirs));
  });

  it('should have denyDirs array with system directories', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.ok(Array.isArray(config.denyDirs));
    assert.ok(config.denyDirs.length > 0, 'denyDirs should not be empty');

    // Should deny Windows system directories
    const denyStr = config.denyDirs.join(' ');
    assert.ok(denyStr.includes('Windows'), 'Should deny C:/Windows');
    assert.ok(denyStr.includes('Program Files'), 'Should deny C:/Program Files');
  });

  it('should have tls config', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.tls, 'object');
    assert.equal(typeof config.tls.enabled, 'boolean');
  });

  it('should have discovery config', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    assert.equal(typeof config.discovery, 'object');
    assert.equal(typeof config.discovery.enabled, 'boolean');
  });

  it('should have matching sharedSecret between relay and worker configs', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    const relayConfig = JSON.parse(fs.readFileSync(path.join(ROOT, 'relay', 'config.json'), 'utf-8'));
    assert.equal(config.sharedSecret, relayConfig.sharedSecret,
      'Worker and relay shared secrets must match');
  });

  it('should not contain real user paths in defaultWorkingDir', () => {
    config = config || JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    // Should use generic placeholder paths, not real user directories
    assert.ok(!config.defaultWorkingDir.match(/C:\/Users\/[a-zA-Z]/),
      'defaultWorkingDir should not contain real user paths');
  });
});
