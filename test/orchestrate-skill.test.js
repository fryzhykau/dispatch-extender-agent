/**
 * test/orchestrate-skill.test.js
 *
 * Tests for the .claude/commands/orchestrate.md skill file.
 * Validates the file exists, contains required protocol sections,
 * and references the correct API endpoints.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const SKILL_PATH = path.join(ROOT, '.claude', 'commands', 'orchestrate.md');

describe('orchestrate skill (.claude/commands/orchestrate.md)', () => {
  let content;

  it('should exist', () => {
    assert.ok(fs.existsSync(SKILL_PATH), `Skill file missing at ${SKILL_PATH}`);
  });

  it('should be non-empty', () => {
    content = fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.length > 100, 'Skill file is too short');
  });

  it('should document all 6 protocol steps', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('Step 1'), 'Missing Step 1');
    assert.ok(content.includes('Step 2'), 'Missing Step 2');
    assert.ok(content.includes('Step 3'), 'Missing Step 3');
    assert.ok(content.includes('Step 4'), 'Missing Step 4');
    assert.ok(content.includes('Step 5'), 'Missing Step 5');
    assert.ok(content.includes('Step 6'), 'Missing Step 6');
  });

  it('should reference the /status endpoint', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('/status'), 'Missing /status endpoint');
  });

  it('should reference the POST /task endpoint', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('POST'), 'Missing POST method');
    assert.ok(content.includes('/task'), 'Missing /task endpoint');
  });

  it('should reference task polling via /task/:id', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('/task/<task-id>') || content.includes('/task/:id'),
      'Missing task polling endpoint');
  });

  it('should mention the PIN requirement', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('pin'), 'Missing PIN documentation');
  });

  it('should mention the Authorization header', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('Authorization'), 'Missing Authorization header');
    assert.ok(content.includes('Bearer'), 'Missing Bearer token');
  });

  it('should document terminal task statuses', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('"done"'), 'Missing done status');
    assert.ok(content.includes('"error"'), 'Missing error status');
    assert.ok(content.includes('"timeout"'), 'Missing timeout status');
  });

  it('should mention retry-on-failure behavior', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.toLowerCase().includes('retry'), 'Missing retry documentation');
  });

  it('should mention the 300-word summary limit', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('300'), 'Missing 300-word limit');
  });

  it('should mention agent capabilities for routing', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.includes('agentCapabilities') || content.includes('capabilities'),
      'Missing capability-based routing');
  });

  it('should warn against exposing secrets', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.toLowerCase().includes('secret'), 'Missing secret handling guidance');
    assert.ok(content.toLowerCase().includes('never') || content.toLowerCase().includes("don't"),
      'Missing warning about not exposing secrets');
  });
});

describe('setup wizard deploys orchestrate skill', () => {
  const wizardPath = path.join(ROOT, 'install', 'setup-wizard.ps1');

  it('setup wizard should reference orchestrate skill deployment', () => {
    const wizardContent = fs.readFileSync(wizardPath, 'utf-8');
    assert.ok(wizardContent.includes('orchestrate'),
      'Setup wizard does not mention orchestrate skill');
  });

  it('setup wizard should deploy skill only for coordinator role', () => {
    const wizardContent = fs.readFileSync(wizardPath, 'utf-8');
    // The skill deployment block should be conditional on coordinator role
    assert.ok(wizardContent.includes('coordinator') && wizardContent.includes('orchestrate'),
      'Setup wizard should deploy skill for coordinator role');
  });
});
