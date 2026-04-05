# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Multi-Machine Claude Dispatch Orchestrator — extends Anthropic's Dispatch (phone → one desktop) to a hub-and-spoke model where a coordinator machine routes subtasks to worker machines over a WebSocket relay.

## Multi-Machine Orchestrator

When given a task from Dispatch:
1. Call `GET http://localhost:7070/status` to see connected machines and their workingDirs.
2. Break the task into subtasks, one per machine where parallel execution makes sense.
3. For each subtask, call `POST http://localhost:7070/task` with `{ machineId, prompt, workingDir }`.
4. Poll `GET http://localhost:7070/task/:id` every 10s until status is "done" or "error".
5. Aggregate all results and reply to Dispatch with a single summary.

Rules:
- Never assign a subtask to a machine that is "busy" in /status.
- If a machine returns "error", retry once on a different available machine.
- Keep the phone-facing summary under 300 words.
- When submitting tasks, include the PIN from config in the POST body (e.g., `{ "pin": "1234" }`).
- You can target a specific agent by name (e.g., `agentName: "CodeBot"`) or by `machineId`. When using agent names, the relay resolves the name to the corresponding machineId (case-insensitive). If both `agentName` and `machineId` are provided, `machineId` takes precedence.

## Commands

```bash
npm run relay        # Start the WebSocket relay server (port 7070)
npm run worker       # Start a worker agent process
npm run test         # Run tests
```

## Architecture

```
relay/
├── server.js          # WebSocket relay + HTTP status API
├── registry.js        # SQLite task state (sql.js)
└── config.json        # shared secret, port, machine list
worker/
├── agent-relay.js     # worker process: WS client + claude runner
└── worker-config.json # machine ID, coordinator host
coordinator/
└── decompose.js       # task decomposition + orchestration logic
install/
├── install-relay.ps1  # register relay as Windows service (NSSM)
├── install-worker.ps1 # register worker as Windows service (NSSM)
├── setup-wizard.ps1   # orchestrator setup wizard (WinForms GUI)
└── inno/              # Inno Setup installer build system
```

## Key Dependencies

- `ws` — WebSocket server and client
- `sql.js` — Pure JS/WASM SQLite for task registry
- `uuid` — Task ID generation
- Node.js 18+ required

## CRITICAL: Never Expose Secrets

**NEVER display, cat, echo, or log the contents of:**
- `.env*` files
- `.dev.vars` (Cloudflare local secrets)
- Any file containing API keys, tokens, or credentials
- Terraform `.tfvars` files with secrets

When debugging env vars, only check existence:
```bash
# GOOD - check if var exists
test -n "$AUTH_SECRET" && echo "AUTH_SECRET is set" || echo "AUTH_SECRET is missing"
grep -l "AUTH_SECRET" .env.local  # just checks if file contains the key

# BAD - exposes secret values
cat .env.local
echo $AUTH_SECRET
grep "AUTH" .env.local
```

## Environment

This project runs on Windows with bash shell. When running commands:
- Use quotes around paths containing spaces (e.g., `cd "path/to/project"`)
- Do NOT use `cd /d` (Windows CMD-specific flag that fails in bash)
- Chain commands with `&&` as usual

## Testing

- **Always create tests for new functionality** - Add E2E or unit tests when implementing new features
- TypeScript must compile without errors before committing

## Pre-Push Workflow

**ALL checks must pass before pushing to any branch. Never skip tests.**

Before pushing changes:

```bash
npm run test         # All tests - MUST pass
npm run pii-check    # PII scan - MUST pass (blocks push if personal info found)
```

### PII / Personal Information Check (MANDATORY before push)

**Before every push to any remote branch**, scan all source files for personal information:

```bash
npm run pii-check
```

This script scans all tracked files (excluding node_modules, .git, data/, logs/, certs/) for:
- **Email addresses** (any `user@domain` pattern)
- **Real names** in paths (e.g., `C:\Users\<realname>\`)
- **IP addresses** (hardcoded non-localhost IPs)
- **Phone numbers**
- **Hardcoded secrets** (anything that looks like a real API key, token, or password — not placeholder values like `CHANGE-ME`)
- **Windows user profile paths** containing real usernames

If any PII is found, the script exits with code 1 and lists every match. **Do NOT push until all findings are resolved.** Replace real paths with placeholders (e.g., `C:/workspace`), move secrets to config files that are gitignored.

### Security & Privacy Review

Before merging to `main`, review changes for:

1. **Authentication & Authorization**
   - All API routes check session/auth state via Bearer token
   - Task submission requires PIN (second factor)
   - Workers validate working directories against allowlist/denylist

2. **Input Validation**
   - All user inputs are validated (type, length, format)
   - Prompts capped at 50,000 chars, output at 1MB
   - Request body size limited to 100KB
   - Path traversal attempts blocked (`..`, UNC paths, null bytes)

3. **Injection Prevention**
   - No raw SQL queries (use parameterized queries via sql.js)
   - User data sanitized before injecting into AI prompts
   - No `dangerouslySetInnerHTML` without sanitization

4. **Secrets & PII**
   - No secrets, real names, or personal paths in source code
   - Config files with secrets (config.json, worker-config.json) use placeholder values in the repo
   - `.env*`, `certs/`, `data/`, `logs/` all in `.gitignore`
   - Error messages don't leak sensitive data
   - Audit logs stored locally, never pushed to remote

### Git Workflow

1. Commit changes to `dev` branch
2. Run lint, typecheck, tests, build locally
3. Review security checklist above
4. Push to `dev`: `git push origin dev`
5. Merge to main: `git checkout main && git pull && git merge dev`
6. Push to production: `git push origin main`
7. Return to dev: `git checkout dev`
