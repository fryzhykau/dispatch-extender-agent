# Specification: Multi-Machine Claude Dispatch Orchestrator

## Overview

Extends Anthropic's Dispatch (phone → one desktop) to a hub-and-spoke model: your phone dispatches tasks through a coordinator machine, which routes subtasks to one or more worker machines over a local WebSocket relay. All Claude Code instances run locally on Windows; the relay is the only new process.

---

## Architecture

**Tier 1 — Phone**
Uses the existing Claude Dispatch pairing (unchanged). The user sends natural-language task instructions from the Claude mobile app.

**Tier 2 — Coordinator (Machine 1)**
Runs Claude Desktop + Cowork with Dispatch paired to the phone. Also runs the relay server as a background Windows service. Receives the phone's task, decomposes it via a Claude Code session, assigns subtasks to worker machines, and reports the aggregated result back to the phone.

**Tier 3 — Relay Server** (runs on Machine 1, port 7070)
A lightweight Node.js `ws` WebSocket server. Maintains a registry of connected worker machines, routes task payloads to the right machine, and stores task state in SQLite.

**Tier 4 — Worker Machines (Machines 2…N)**
Each runs `agent-relay.js`, a small Node.js process that holds an open WebSocket connection to the relay and spawns `claude --print` subprocesses on demand.

---

## File Structure

```
dispatch-orchestrator/
├── relay/
│   ├── server.js          # WebSocket relay + HTTP status API
│   ├── registry.js        # SQLite task state (better-sqlite3)
│   └── config.json        # shared secret, port, machine list
├── worker/
│   ├── agent-relay.js     # worker process: WS client + claude runner
│   └── worker-config.json # machine ID, coordinator host
├── coordinator/
│   └── decompose.js       # Claude Code skill: task → subtask list
├── install/
│   ├── install-relay.ps1  # register relay as Windows service (NSSM)
│   └── install-worker.ps1 # register worker as Windows service (NSSM)
└── CLAUDE.md              # coordinator skill loaded by Dispatch
```

---

## Communication Protocol

All messages are JSON over WebSocket.

**Worker → Relay on connect:**
```json
{ "type": "register", "machineId": "machine-2", "token": "<shared-secret>" }
```

**Relay → Worker, task dispatch:**
```json
{
  "type": "task",
  "taskId": "uuid",
  "prompt": "Summarise all PDFs in D:/reports and return bullet points",
  "workingDir": "D:/reports",
  "timeout": 120000
}
```

**Worker → Relay, result:**
```json
{
  "type": "result",
  "taskId": "uuid",
  "machineId": "machine-2",
  "status": "done",
  "output": "...",
  "durationMs": 34200
}
```

**Relay HTTP API** (coordinator polls this):
- `GET /status` — list all connected machines and their states
- `GET /task/:id` — get task result by ID
- `POST /task` — submit a task (body: `{ machineId, prompt, workingDir }`)

---

## Key Dependencies

| Package | Purpose |
|---|---|
| `ws` | WebSocket server and client |
| `better-sqlite3` | Synchronous SQLite for task registry |
| `uuid` | Task ID generation |
| `node-fetch` or built-in `fetch` | Coordinator polling relay HTTP API |
| `NSSM` (external) | Register Node.js processes as Windows services |

Node.js 18+ required (Claude Code dependency, also used here).

---

## Coordinator Skill (`CLAUDE.md`)

The coordinator Claude session reads this file on every Dispatch task. It defines the orchestration workflow:

```markdown
# Multi-machine orchestrator

When given a task from Dispatch:
1. Call GET http://localhost:7070/status to see connected machines and their workingDirs.
2. Break the task into subtasks, one per machine where parallel execution makes sense.
3. For each subtask, call POST http://localhost:7070/task with { machineId, prompt, workingDir }.
4. Poll GET http://localhost:7070/task/:id every 10s until status is "done" or "error".
5. Aggregate all results and reply to Dispatch with a single summary.

Rules:
- Never assign a subtask to a machine that is "busy" in /status.
- If a machine returns "error", retry once on a different available machine.
- Keep the phone-facing summary under 300 words.
```

---

## Worker Behaviour (`agent-relay.js`)

1. On startup, connects to relay via WebSocket and sends `register`.
2. On receiving a `task` message, spawns:
   ```
   claude --print --dangerously-skip-permissions "<prompt>"
   ```
   with `cwd` set to `workingDir` from the task payload.
3. Captures stdout, sends `result` message back to relay when the process exits.
4. Handles `timeout` by killing the subprocess and sending `status: "timeout"`.
5. Reconnects automatically on relay disconnect (exponential backoff, max 30s).

---

## Security

- All WebSocket connections are authenticated with a shared secret in `config.json`. Connections that send a wrong token are immediately closed.
- The relay binds to `0.0.0.0:7070` but should sit behind the Windows Firewall, accessible only from the local network (or VPN). Do not expose port 7070 to the internet.
- `--dangerously-skip-permissions` is used on workers to allow unattended runs. Scope each worker's `workingDir` tightly to only the folder it should operate on.
- Rotate the shared secret by updating `config.json` on all machines and restarting services.

---

## Windows Service Installation

Both the relay and each worker should be registered as Windows services using NSSM so they survive reboots and run without a logged-in user.

```powershell
# install-relay.ps1 (run on Machine 1)
nssm install DispatchRelay "C:\Program Files\nodejs\node.exe"
nssm set DispatchRelay AppDirectory "C:\dispatch-orchestrator\relay"
nssm set DispatchRelay AppParameters "server.js"
nssm set DispatchRelay Start SERVICE_AUTO_START
nssm start DispatchRelay

# install-worker.ps1 (run on each worker machine)
nssm install DispatchWorker "C:\Program Files\nodejs\node.exe"
nssm set DispatchWorker AppDirectory "C:\dispatch-orchestrator\worker"
nssm set DispatchWorker AppParameters "agent-relay.js"
nssm set DispatchWorker Start SERVICE_AUTO_START
nssm start DispatchWorker
```

---

## Phase 2 Scope

- Browser/UI dashboard for task history (add later)
- End-to-end encryption of WebSocket traffic (add TLS termination if needed)
- Dynamic machine discovery (static config list is sufficient for v1)
- Load balancing across identical machines (coordinator assigns explicitly)

---

## Suggested Build Order for Claude Code

1. `relay/registry.js` — SQLite schema and CRUD helpers
2. `relay/server.js` — WebSocket server with registration and task routing
3. `worker/agent-relay.js` — WS client + claude subprocess runner
4. `coordinator/decompose.js` — test task decomposition with a simple prompt
5. `CLAUDE.md` — wire up the Dispatch skill end-to-end
6. `install/*.ps1` — service registration scripts
7. Integration test: phone → coordinator → two workers → aggregated reply
