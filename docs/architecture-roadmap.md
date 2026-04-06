# Architecture Roadmap & Design Document

This document captures the architectural analysis, identified limitations, and planned evolution of the Multi-Machine Claude Dispatch Orchestrator.

## Current Architecture

```
Phone → Dispatch → Cowork (cloud sandbox)
                      ↓
              [local code session]     ← friction point
                      ↓
              curl → Relay (localhost:7070) → Workers (WebSocket)
                      ↓
              Aggregated response → Phone
```

### Components

| Component | Location | Role |
|-----------|----------|------|
| **Relay** (`relay/server.js`) | Coordinator machine, localhost | HTTP + WebSocket server, task CRUD, SQLite state, queue, heartbeats, auth, audit |
| **Workers** (`worker/agent-relay.js`) | Agent machines | WebSocket client, receives tasks, spawns `claude --print`, returns results |
| **Skill** (`.claude/skills/orchestrate/SKILL.md`) | Deployed to Claude | Natural-language instructions teaching Claude to call the relay HTTP API via curl |
| **Coordinator logic** (`coordinator/decompose.js`, `load-balancer.js`) | Repo (unused at runtime) | Task decomposition and load balancing — currently duplicated in prose in the skill |
| **Dashboard** (`dashboard/index.html`) | Served by relay | Real-time web UI for monitoring agents, tasks, and queue |

### Current Auth Model

| Layer | Protects | Mechanism |
|-------|----------|-----------|
| Shared secret | WebSocket + HTTP API | Single Bearer token, same on all machines |
| PIN | Task submission | 4-digit code, user provides per request, lockout after 5 failures |

---

## Identified Limitations

### 1. Cowork sandbox cannot reach localhost

**The single biggest friction point.** Cowork and Dispatch run in isolated cloud containers. The relay runs on `localhost:7070`. When the orchestrate skill is invoked, Claude must request a local code session (folder trust approval) to access the relay. This adds manual friction and breaks the seamless phone → agents flow.

### 2. Skill-based orchestration is fragile

The SKILL.md teaches Claude to construct `curl` commands in prose. Claude can forget headers, malform JSON, misparse responses, or poll incorrectly. The tested `decompose.js` and `load-balancer.js` code is never actually called — the skill duplicates their logic in natural language.

### 3. Secrets in Claude's context

The skill instructs Claude to read `config.json` and use the shared secret in curl commands. This means the secret passes through Claude's conversation context, where it could leak in summaries or logs.

### 4. Single shared secret

All machines use the same token. Compromise of one machine compromises the entire system. No per-machine revocation.

### 5. Workers self-report identity

Any process with the shared secret can register as any `machineId` with any capabilities. No enrollment or approval process. (Partially mitigated: duplicate registrations now close the stale connection, result messages are validated against the dispatched machine.)

### 6. Single point of failure

The relay runs as a single process on one machine. If that machine reboots or crashes, all orchestration stops.

---

## Phase 1: Cloud-Hosted Relay

**Goal:** Eliminate the localhost limitation. Cowork calls the relay directly.

**Effort:** Low — deploy existing code, config changes only.

### Changes

1. Deploy `server.js` to a small VPS (DigitalOcean $6/mo, Hetzner $4/mo, Oracle Cloud free tier)
2. Enable TLS (`tls.enabled: true` in config, certs from Let's Encrypt)
3. Workers connect via `wss://relay.yourdomain.com` instead of `ws://localhost:7070`
4. Skill uses `https://relay.yourdomain.com` instead of `http://localhost:7070`
5. Remove the "request a local code session" instruction from the skill

### Per-Machine API Keys

Replace the single shared secret with unique tokens per machine:

```
machines table (SQLite):
  machineId TEXT PRIMARY KEY
  apiKey TEXT UNIQUE
  agentName TEXT
  enrolledAt INTEGER
  lastSeen INTEGER
  revoked BOOLEAN DEFAULT false
```

**Enrollment flow:**
1. Admin calls `POST /admin/enroll { machineId, agentName }` → returns a one-time enrollment token
2. Worker installer receives the enrollment token (entered in the setup wizard)
3. On first WebSocket connect, worker sends the enrollment token
4. Relay validates it, generates a permanent per-machine API key, returns it
5. Worker stores the key in `worker-config.json`
6. Subsequent connections use the permanent key
7. Admin can revoke individual keys via `POST /admin/revoke { machineId }`

### What This Solves

- Cowork can reach the relay directly (no local code session)
- Workers on different networks (home, office, VPN) can all connect
- Relay survives individual machine reboots
- Per-machine revocation without affecting other machines
- Audit logs tied to specific machine identities

### What It Doesn't Solve

- Secrets still pass through Claude's context (skill still uses curl)
- Decompose logic still duplicated in prose
- No structured tool interface

---

## Phase 2: MCP Server (Replace SKILL.md)

**Goal:** Replace the fragile skill with native MCP tool calls. Secrets never enter Claude's context.

**Effort:** Medium — ~400 lines of new code for the MCP server.

### Architecture

```
Phone → Dispatch → Cowork (cloud sandbox)
                      ↓
              MCP tool call (orchestrate)     ← no curl, no secrets in context
                      ↓
              MCP Server (VPS) → Relay API → Workers
                      ↓
              Structured response → Phone
```

### MCP Tool Surface

| Tool | Parameters | Returns | Description |
|------|-----------|---------|-------------|
| `list_agents` | none | `agents[]` | Connected agents with status, capabilities, working dirs |
| `dispatch_task` | `prompt, agentName?, machineId?, workingDir?, pin` | `{ taskId, status }` | Submit a task, return immediately |
| `dispatch_and_wait` | `prompt, agentName?, machineId?, workingDir?, pin, timeoutMs?` | `{ taskId, status, output, durationMs }` | Submit and poll until completion |
| `check_task` | `taskId` | `{ taskId, status, output, durationMs }` | Check status of a previously submitted task |
| `orchestrate` | `taskDescription, pin` | `{ subtasks[], summary }` | Full orchestration: decompose, dispatch, poll, retry, aggregate |

### Authentication Chain

```
Cowork → [MCP auth token] → MCP Server → [relay API key] → Relay → Workers
         (in config,                       (server-side,
          never in chat)                    never in chat)
```

**Two separate auth boundaries:**

#### Boundary 1: Cowork → MCP Server

The MCP server is a remote HTTP endpoint (`https://your-vps.com/mcp`). Authentication options:

**Option A: Static token (simplest, recommended for single-user)**

Cowork configuration:
```json
{
  "type": "url",
  "url": "https://your-vps.com/mcp",
  "authorization_token": "YOUR_MCP_TOKEN"
}
```

Claude Code CLI configuration (`.mcp.json`):
```json
{
  "mcpServers": {
    "relay": {
      "type": "http",
      "url": "https://your-vps.com/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_MCP_TOKEN"
      }
    }
  }
}
```

The MCP server validates the Bearer token on every request. The token is stored in config files, never in Claude's conversation.

**Option B: OAuth 2.0 (for multi-user or shared deployments)**

- MCP server exposes OAuth endpoints (`/authorize`, `/token`)
- Cowork redirects user to authorize, gets an access token
- Tokens refresh automatically
- Better for teams where each user needs their own access level

**Option C: Dynamic headers (for short-lived tokens)**

Claude Code CLI only:
```json
{
  "mcpServers": {
    "relay": {
      "type": "http",
      "url": "https://your-vps.com/mcp",
      "headersHelper": "get-relay-token.sh"
    }
  }
}
```

The helper script runs on each connection and outputs JSON headers. Useful for SSO/internal auth.

#### Boundary 2: MCP Server → Relay API

The MCP server holds the relay's API key **internally** in its own configuration. It reads the key from its server-side config (e.g., environment variable or config file on the VPS). Claude never sees this key.

```
MCP Server internals:
  1. Validates incoming Cowork/CLI auth token
  2. Reads relay API key from server-side config
  3. Calls relay HTTP API with Authorization: Bearer <relay-api-key>
  4. Returns structured results to Cowork/CLI
```

#### PIN Handling

The PIN remains a user-provided second factor. It flows through the MCP tool parameter:

```
User (phone): "Deploy to staging on machine-3"
Claude: calls orchestrate(task="Deploy to staging", pin=?)
Claude: "What's your PIN?"
User: "4827"
Claude: calls orchestrate(task="Deploy to staging on machine-3", pin="4827")
MCP Server: POST /task { ..., pin: "4827" } → Relay validates PIN
```

The PIN passes through Claude's context (the user speaks it on the phone), but the shared secret / API key never does.

### Session-Based PIN

To reduce friction on multi-task phone calls:

1. First `dispatch_task` call includes the PIN
2. Relay validates PIN, returns a session token (30-minute TTL)
3. MCP server caches the session token
4. Subsequent calls in the same session skip the PIN
5. Session expires after 30 minutes of inactivity

### What This Solves

- Secrets never in Claude's context
- No SKILL.md to maintain or deploy
- Structured, typed tool calls instead of curl command construction
- Existing `decompose.js` and `load-balancer.js` actually get used
- Works natively from Cowork, Code tab, CLI, and Dispatch
- Server-side polling (no Claude compute wasted on curl loops)

---

## Phase 3: Scale and Harden

**Goal:** Production-grade infrastructure for larger deployments.

### Merge MCP Server and Relay

The MCP server and relay are currently separate concerns but can be a single process:

```
Single process:
  - HTTP endpoints: /status, /task, /tasks, /stats, /dashboard (relay API)
  - MCP endpoint: /mcp (streamable HTTP, tool calls)
  - WebSocket: worker connections
  - SQLite: task state
```

This eliminates the MCP → relay HTTP hop (they share the same process and database).

### Database Upgrade

Replace sql.js (in-memory, WASM) with better-sqlite3 (native, disk-based):
- Faster queries at scale
- WAL mode for concurrent reads during writes
- No full-DB export on every save
- Handles 100K+ tasks without memory pressure

### Worker Enrollment

Formalized registration process:

1. Admin generates enrollment token: `POST /admin/enroll { machineId, capabilities }`
2. Token is entered in the worker setup wizard
3. On first connect, worker exchanges token for a permanent API key
4. Relay maintains an allowlist — unknown machines are rejected
5. Keys are individually revocable

### Cloudflare Workers + Durable Objects (Optional)

If multi-region or managed infrastructure is needed:

```
Current relay/server.js  →  CF Worker (HTTP routes) + Durable Object (WebSocket + state)
registry.js (sql.js)     →  DO transactional storage (SQLite)
queue.js                 →  DO alarm-based drain
discovery.js (UDP)       →  Not needed (workers connect to a fixed URL)
audit.js                 →  CF Logpush or Workers Analytics Engine
```

**Gains:** No VPS to manage, global edge, auto-scaling, WebSocket hibernation.
**Loses:** Vendor lock-in, full rewrite of relay, harder debugging.
**When:** Only if the project grows to external users or multi-region.

---

## Scalability Analysis

| Scale | Bottleneck | Fix |
|-------|-----------|-----|
| 10 agents | None | Current architecture is fine |
| 50 agents | `registry.save()` writes full DB on every task | Batch saves (every 5s or 10 changes) |
| 50 agents | `/stats` full table scan | Add summary counters updated on task completion |
| 100 agents | sql.js memory usage with 10K+ tasks | Switch to better-sqlite3 |
| 100 agents | Single-process relay | Add reverse proxy (nginx/Caddy) for TLS termination |
| 100+ agents | Claude API rate limits | The real bottleneck — each worker makes concurrent API calls to Anthropic |

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| Hub-and-spoke over peer-to-peer | Fan-out/fan-in pattern needs a rendezvous point; P2P adds NAT traversal complexity |
| Custom relay over message queue (NATS, RabbitMQ) | Relay is more than a bus — it's also HTTP API, task state, agent registry, dashboard. MQ would only replace the transport layer |
| MCP server over enhanced SKILL.md | Structured tool calls are more reliable than prose-instructed curl commands; secrets stay server-side |
| Per-machine API keys over shared secret | Individual revocation, audit attribution, reduced blast radius on compromise |
| Static auth token over OAuth (Phase 2) | Simpler for single-user deployment; OAuth can be added later for multi-user |
| VPS over Cloudflare Workers (Phase 1) | Zero code changes to deploy existing server.js; CF Workers requires a full rewrite |
| PIN as user-provided (not from config) | Second factor should verify human presence, not be automatable from a file |
