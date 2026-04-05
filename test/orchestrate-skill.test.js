/**
 * test/orchestrate-skill.test.js
 *
 * Tests for the .claude/skills/orchestrate/SKILL.md skill file.
 * Validates the file exists, contains required protocol sections,
 * references the correct API endpoints, and has valid frontmatter.
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const SKILL_PATH = path.join(ROOT, '.claude', 'skills', 'orchestrate', 'SKILL.md');

describe('orchestrate skill (.claude/skills/orchestrate/SKILL.md)', () => {
  let content;

  it('should exist', () => {
    assert.ok(fs.existsSync(SKILL_PATH), `Skill file missing at ${SKILL_PATH}`);
  });

  it('should be non-empty', () => {
    content = fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.length > 100, 'Skill file is too short');
  });

  it('should have valid YAML frontmatter with name and description', () => {
    content = content || fs.readFileSync(SKILL_PATH, 'utf-8');
    assert.ok(content.startsWith('---'), 'Missing frontmatter opening ---');
    const endIdx = content.indexOf('---', 3);
    assert.ok(endIdx > 3, 'Missing frontmatter closing ---');
    const frontmatter = content.substring(3, endIdx);
    assert.ok(frontmatter.includes('name: orchestrate'), 'Missing name field');
    assert.ok(frontmatter.includes('description:'), 'Missing description field');
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
    assert.ok(wizardContent.includes('coordinator') && wizardContent.includes('orchestrate'),
      'Setup wizard should deploy skill for coordinator role');
  });

  it('setup wizard should bake secret and PIN into skill', () => {
    const wizardContent = fs.readFileSync(wizardPath, 'utf-8');
    assert.ok(wizardContent.includes('cfgSecret') && wizardContent.includes('cfgPin'),
      'Setup wizard should inject secret and PIN into skill');
  });

  it('setup wizard should have a Copy Cowork Prompt button', () => {
    const wizardContent = fs.readFileSync(wizardPath, 'utf-8');
    assert.ok(wizardContent.includes('Copy Cowork Prompt'),
      'Setup wizard should have Cowork prompt copy button');
  });
});

describe('Cowork skill-creator prompt template', () => {
  const promptPath = path.join(ROOT, 'install', 'cowork-skill-prompt.txt');

  it('should exist', () => {
    assert.ok(fs.existsSync(promptPath), 'Cowork prompt template missing');
  });

  it('should contain placeholders for secret, PIN, and port', () => {
    const content = fs.readFileSync(promptPath, 'utf-8');
    assert.ok(content.includes('{{SECRET}}'), 'Missing {{SECRET}} placeholder');
    assert.ok(content.includes('{{PIN}}'), 'Missing {{PIN}} placeholder');
    assert.ok(content.includes('{{PORT}}'), 'Missing {{PORT}} placeholder');
  });

  it('should reference the orchestrate skill name', () => {
    const content = fs.readFileSync(promptPath, 'utf-8');
    assert.ok(content.includes('"orchestrate"'), 'Missing skill name');
  });

  it('should include the full protocol (all 6 steps)', () => {
    const content = fs.readFileSync(promptPath, 'utf-8');
    assert.ok(content.includes('Step 1'), 'Missing Step 1');
    assert.ok(content.includes('Step 2'), 'Missing Step 2');
    assert.ok(content.includes('Step 3'), 'Missing Step 3');
    assert.ok(content.includes('Step 4'), 'Missing Step 4');
    assert.ok(content.includes('Step 5'), 'Missing Step 5');
    assert.ok(content.includes('Step 6'), 'Missing Step 6');
  });
});
