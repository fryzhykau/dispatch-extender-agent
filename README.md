# Multi-Machine Claude Dispatch Orchestrator

> **Platform: Windows only.** This project is built and tested exclusively on Windows (10/11). Service installation uses NSSM and PowerShell, sleep prevention uses the Win32 `SetThreadExecutionState` API, and paths assume Windows conventions. It has **not been tested** on macOS or Linux. Contributions to add cross-platform support are welcome.

Extends Anthropic's [Dispatch](https://docs.anthropic.com/en/docs/claude-code/dispatch) (phone to one desktop) into a hub-and-spoke model: your phone dispatches tasks through a coordinator machine, which routes subtasks to one or more named worker agents over a local WebSocket relay.

```
Phone (Claude App)
  │
  ▼
Coordinator (Machine 1)          Relay Server (port 7070)
  Claude Desktop + Dispatch  ──▶  WebSocket + HTTP API
                                    │          │
                              ┌─────┘          └─────┐
                              ▼                      ▼
                        Worker "CodeBot"       Worker "ResearchBot"
                        (Machine 2)            (Machine 3)
                        claude --print         claude --print
```

## What This Enables (Beyond Standard Dispatch)

Standard Dispatch pairs your phone to **one** desktop. This orchestrator removes that limitation and opens up scenarios that aren't possible otherwise:

### Parallel multi-machine work
> *"Hey Claude, run the full test suite on my dev machine AND do a security audit of the auth module on my workstation — give me a combined report."*

Both tasks run simultaneously on different machines. You get one aggregated answer on your phone.

### Named specialist agents
> *"Ask CodeBot to refactor the payment service to use Stripe v3, and have ResearchBot find the top 5 competitor pricing pages."*

Each machine has a personality and capabilities. Route work to the right agent by name, like delegating to team members.

### Remote fleet orchestration from your phone
> *"Deploy the staging build on machine-3, then run smoke tests on machine-4 against the staging URL."*

Trigger multi-step workflows across your home lab, office machines, or cloud VMs — all from your phone while you're away from your desk.

### Unattended overnight batch processing
> *"Process all 200 PDF invoices in D:/invoices — split them across all available machines and extract line items into a spreadsheet."*

With sleep prevention enabled, machines stay awake and grind through large batch jobs overnight. Task queue ensures nothing is dropped even if all machines are temporarily busy.

### Capability-based auto-routing
> *"Analyze this codebase for performance bottlenecks."*

You don't even need to pick a machine. The coordinator matches keywords in your request against agent capabilities and load-balances across idle workers automatically.

### Live monitoring dashboard
> *Open `http://coordinator:7070/dashboard` from any device on your network.*

See which agents are connected, what they're working on, task history, queue depth, and performance stats — all in real time.

## Prerequisites

- **Node.js 18+** on all machines
- **Claude Code CLI** installed on all worker machines
- **NSSM** (optional) for running as Windows services
- **OpenSSL** (optional, ships with Git for Windows) for TLS certificate generation

## Quick Start

### 1. Install dependencies

```bash
npm install
```

### 2. Configure the shared secret

Generate a strong secret and set it in both config files (must match):

```bash
# Generate a random secret
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

Edit `relay/config.json` and `worker/worker-config.json` — replace `"CHANGE-ME-generate-a-real-secret"` with your generated secret.

### 3. Set the PIN

Edit `relay/config.json` — change `pin.code` from `"1234"` to your chosen PIN. This is a second factor required for task submission.

### 4. Start the relay (Machine 1)

```bash
npm run relay
```

You should see:

```
[relay] Task registry initialized
[relay] Ready — listening on 0.0.0.0:7070
[relay] Discovery broadcasting is active
```

### 5. Start a worker (Machine 2+)

Edit `worker/worker-config.json`:
- Set `machineId` to a unique ID (e.g., `"machine-2"`)
- Set `agentName` to a friendly name (e.g., `"CodeBot"`)
- Set `coordinatorHost` to the relay address (e.g., `"ws://192.168.1.100:7070"`) or `"auto"` for discovery
- Set `defaultWorkingDir` to the folder the agent should operate in
- Add allowed directories to `allowedDirs`

```bash
npm run worker
```

### 6. Open the dashboard

Navigate to `http://localhost:7070/dashboard` in your browser. Enter your Bearer token (the shared secret) in settings.

## Architecture

### File Structure

```
relay/
├── server.js          # WebSocket relay + HTTP API + dashboard serving
├── registry.js        # SQLite task state (sql.js, pure WASM)
├── config.json        # Relay configuration (all features)
├── audit.js           # Structured JSONL audit logging
├── discovery.js       # UDP broadcast for auto-discovery
└── queue.js           # Task queue for busy machines

worker/
├── agent-relay.js     # WS client + claude subprocess runner
├── worker-config.json # Agent identity, security, and connection config
└── discovery.js       # UDP listener for relay auto-discovery

coordinator/
├── decompose.js       # Task decomposition + orchestration
└── load-balancer.js   # Multi-strategy load balancing

dashboard/
└── index.html         # Single-page monitoring UI (no build tools)

lib/
└── keep-awake.js      # Windows sleep prevention (shared)

install/
├── install-relay.ps1  # Register relay as Windows service (NSSM)
├── install-worker.ps1 # Register worker as Windows service (NSSM)
└── generate-certs.ps1 # Generate TLS certificates (OpenSSL)
```

### Communication Flow

1. **Phone** sends a task via Claude Dispatch to the coordinator
2. **Coordinator** decomposes the task, calls `POST /task` on the relay for each subtask
3. **Relay** routes each subtask to the target worker via WebSocket
4. **Worker** spawns `claude --print --dangerously-skip-permissions "<prompt>"` and captures output
5. **Worker** sends the result back through the relay
6. **Coordinator** aggregates all results and replies to the phone

### Protocol

All messages are JSON over WebSocket:

| Direction | Type | Purpose |
|-----------|------|---------|
| Worker to Relay | `register` | Authenticate and announce agent identity |
| Relay to Worker | `task` | Dispatch a task with prompt and workingDir |
| Worker to Relay | `result` | Return task output, status, and duration |
| Relay to Worker | `ping` | Heartbeat check |
| Worker to Relay | `pong` | Heartbeat response with current status |

### HTTP API

All API endpoints require `Authorization: Bearer <shared-secret>` header.

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/status` | Connected machines, agents, and their states |
| `GET` | `/task/:id` | Get a specific task by ID |
| `GET` | `/tasks` | List tasks (filter: `?status=`, `?machineId=`, `?limit=`, `?offset=`) |
| `GET` | `/stats` | Per-machine performance statistics |
| `GET` | `/queue` | Current task queue status |
| `GET` | `/audit` | Audit log entries (filter: `?event=`, `?level=`, `?limit=`) |
| `POST` | `/task` | Submit a task (requires PIN) |
| `GET` | `/dashboard` | Web UI |

#### POST /task body

```json
{
  "agentName": "CodeBot",
  "prompt": "Refactor the auth module to use JWT",
  "workingDir": "C:/projects/my-app",
  "pin": "1234"
}
```

You can target by `agentName` (friendly name, case-insensitive) or `machineId`. Use `"machineId": "any"` to let the load balancer choose. If the target is busy, the task is queued and a `202 Accepted` response is returned.

## Named Agents

Workers register with a human-friendly name and capabilities:

```json
{
  "agentName": "CodeBot",
  "agentDescription": "Handles coding tasks, refactoring, and code review",
  "agentCapabilities": ["code", "refactor", "review", "debug"]
}
```

From your phone, you can say things like:
- *"Send this to CodeBot"*
- *"Have ResearchBot look into this"*
- *"Ask CodeBot to refactor the auth module"*

The coordinator automatically matches task keywords to agent capabilities when deciding where to route subtasks.

## Security

### Multi-Layer Authentication

| Layer | Protects | Mechanism |
|-------|----------|-----------|
| **Shared Secret** | WebSocket connections | Token sent on `register`, wrong token = immediate disconnect |
| **Bearer Token** | HTTP API | `Authorization: Bearer` header on all API endpoints |
| **PIN Code** | Task submission | Second factor on `POST /task` with per-IP lockout (5 attempts, 15 min) |

### Path Safety

- **Allowlist**: Workers only execute in directories listed in `allowedDirs`
- **Denylist**: System directories (`C:/Windows`, `C:/Program Files`, etc.) are blocked
- **Path traversal protection**: `..` segments, UNC paths, and null bytes are rejected at both relay and worker levels
- **Directory validation**: Worker verifies the directory exists before spawning

### Input Limits

| Limit | Default | Config Key |
|-------|---------|------------|
| Prompt length | 50,000 chars | `limits.maxPromptLength` |
| Output length | 1,000,000 chars | `limits.maxOutputLength` |
| Request body | 100 KB | `limits.maxRequestBodyBytes` |
| Tasks per minute | 10 | `rateLimiting.maxTasksPerMinute` |
| Tasks per hour | 100 | `rateLimiting.maxTasksPerHour` |

### Audit Logging

All security events are logged to `data/audit.log` (JSONL format):
- Task submissions and completions
- Worker connections and disconnections
- Authentication failures
- PIN failures and lockouts
- Path validation denials
- Rate limit hits

View recent logs: `GET /audit?level=error&limit=50`

### TLS Encryption (Optional)

Enable encrypted WebSocket (WSS) and HTTPS:

```powershell
# Generate certificates
.\install\generate-certs.ps1

# Enable in relay/config.json
# Set tls.enabled = true

# Enable in worker/worker-config.json
# Set tls.enabled = true
# Change coordinatorHost from ws:// to wss://
```

## Features

### Task Queue

When all workers are busy, tasks are queued instead of rejected. The queue drains automatically as workers become idle. Configure with `queue.maxQueueSize` (default: 100).

### Load Balancing

Four strategies for distributing tasks across workers:

| Strategy | Description |
|----------|-------------|
| `round-robin` | Rotate through idle workers in order |
| `least-busy` | Pick the worker with fewest recent tasks (default) |
| `fastest` | Pick the worker with lowest average task duration |
| `random` | Random selection from idle workers |

Set in `relay/config.json` under `loadBalancing.strategy`.

### Auto-Discovery

Workers can find the relay automatically without hardcoding the address. The relay broadcasts UDP announcements on port 7071. Set `coordinatorHost` to `"auto"` in worker config to use discovery.

### Heartbeat Monitoring

The relay pings all workers every 30 seconds. Workers that don't respond within 10 seconds are disconnected and their running tasks are marked as errors. Configure intervals in `relay/config.json` under `heartbeat`.

### Sleep Prevention

Both the relay and workers prevent Windows from sleeping while active. Uses the Windows `SetThreadExecutionState` API. Disable with `keepAwake.enabled: false` in config.

### Dashboard

A real-time web dashboard at `http://localhost:7070/dashboard` showing:
- Connected agents with status, capabilities, and health
- Task history with filtering and pagination
- Task submission form with agent targeting
- Queue status indicator
- Auto-refresh (5 second interval, toggleable)

## Windows Service Installation

Run as persistent background services that survive reboots:

```powershell
# On the coordinator (Machine 1)
.\install\install-relay.ps1

# On each worker machine
.\install\install-worker.ps1
```

Requires [NSSM](https://nssm.cc/) on PATH. Logs are written to the `logs/` directory.

## Configuration Reference

### relay/config.json

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `port` | number | `7070` | Relay server port |
| `sharedSecret` | string | — | Authentication token (change this!) |
| `machines` | array | — | Registered machine list with default working dirs |
| `tls.enabled` | boolean | `false` | Enable HTTPS/WSS |
| `discovery.enabled` | boolean | `true` | Enable UDP broadcast discovery |
| `discovery.broadcastPort` | number | `7071` | UDP broadcast port |
| `heartbeat.intervalMs` | number | `30000` | Ping interval |
| `heartbeat.timeoutMs` | number | `10000` | Pong timeout before disconnect |
| `loadBalancing.strategy` | string | `"least-busy"` | Load balancing strategy |
| `rateLimiting.enabled` | boolean | `true` | Enable rate limiting |
| `rateLimiting.maxTasksPerMinute` | number | `10` | Max tasks per minute |
| `rateLimiting.maxTasksPerHour` | number | `100` | Max tasks per hour |
| `limits.maxPromptLength` | number | `50000` | Max prompt characters |
| `limits.maxOutputLength` | number | `1000000` | Max output characters |
| `limits.maxRequestBodyBytes` | number | `102400` | Max HTTP body size |
| `keepAwake.enabled` | boolean | `true` | Prevent Windows sleep |
| `queue.enabled` | boolean | `true` | Enable task queuing |
| `queue.maxQueueSize` | number | `100` | Max queued tasks |
| `pin.enabled` | boolean | `true` | Require PIN for task submission |
| `pin.code` | string | `"1234"` | PIN code (change this!) |
| `pin.maxAttempts` | number | `5` | Failed attempts before lockout |
| `pin.lockoutMinutes` | number | `15` | Lockout duration |

### worker/worker-config.json

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `machineId` | string | — | Unique machine identifier |
| `agentName` | string | — | Human-friendly agent name |
| `agentDescription` | string | — | What this agent does |
| `agentCapabilities` | string[] | — | Capability keywords for task matching |
| `coordinatorHost` | string | — | Relay WebSocket URL or `"auto"` for discovery |
| `sharedSecret` | string | — | Must match relay's `sharedSecret` |
| `defaultWorkingDir` | string | — | Default working directory |
| `allowedDirs` | string[] | — | Directories the agent may operate in |
| `denyDirs` | string[] | — | Directories the agent must never touch |
| `tls.enabled` | boolean | `false` | Use WSS instead of WS |
| `discovery.enabled` | boolean | `true` | Use UDP discovery to find relay |
| `maxOutputLength` | number | `1000000` | Truncate output beyond this |
| `keepAwake.enabled` | boolean | `true` | Prevent Windows sleep |

## Testing

All tests must pass before pushing to any branch:

```bash
npm test             # Run all 66 tests (unit + integration)
npm run pii-check    # Scan for personal information in source code
npm run precommit    # Runs both pii-check and tests
```

**Test suites:**

| Suite | File | Tests | What it covers |
|-------|------|-------|----------------|
| Registry | `test/registry.test.js` | 21 | SQLite CRUD, filtering, pagination, persistence |
| Server | `test/server.test.js` | 18 | HTTP API auth, validation, WebSocket auth, rate limiting, path traversal |
| Worker | `test/worker.test.js` | 13 | Path allowlist/denylist, normalization, traversal attacks |
| Load Balancer | `test/load-balancer.test.js` | 14 | All 4 strategies, edge cases |

The server integration tests spawn a real relay process on port 7099 with a temporary config, so they validate the full stack end-to-end.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Worker can't connect | Check `sharedSecret` matches in both configs. Check firewall allows port 7070. |
| "Unauthorized" on API calls | Include `Authorization: Bearer <shared-secret>` header. |
| "Invalid PIN" on task submit | Check `pin.code` in `relay/config.json`. After 5 failures, wait 15 minutes or restart relay. |
| "Working directory denied" | Add the directory to `allowedDirs` in worker config. |
| Worker marked as dead | Increase `heartbeat.timeoutMs` if network is slow. |
| Tasks stuck in queue | Check that workers are connected and idle via `GET /status`. |
| Discovery not working | Ensure UDP port 7071 is open. Both machines must be on the same subnet for broadcast. |
| TLS handshake fails | Regenerate certs with `.\install\generate-certs.ps1 -Force`. Ensure CA cert is the same on relay and workers. |

## Platform Support

| Platform | Status |
|----------|--------|
| Windows 10/11 | Tested and supported |
| macOS | Not tested |
| Linux | Not tested |

Windows-specific features (sleep prevention, NSSM services, PowerShell cert generation) will not work on other platforms. The core relay and worker logic (Node.js/WebSocket) is platform-agnostic in principle but has not been validated outside Windows.

## License

Private project.
