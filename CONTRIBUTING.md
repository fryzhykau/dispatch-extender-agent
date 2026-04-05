# Contributing to Dispatch Orchestrator

Thanks for your interest in contributing! This project extends Anthropic's Dispatch into a multi-machine orchestration system.

## Getting Started

1. Fork the repository
2. Clone your fork and install dependencies:
   ```bash
   git clone https://github.com/<your-username>/dispatch-extender-agent.git
   cd dispatch-extender-agent
   npm install
   ```
3. Create a feature branch: `git checkout -b my-feature`

## Development

```bash
npm run relay        # Start the relay server
npm run worker       # Start a worker agent
npm test             # Run all tests (must pass before submitting)
npm run pii-check    # Scan for personal information (must pass)
```

## Before Submitting a PR

All checks must pass:

```bash
npm run precommit    # Runs pii-check + full test suite
```

### Code Guidelines

- **No secrets in source** — Use placeholder values like `CHANGE-ME` in config files. Real secrets go in `.env` or user-configured config.
- **No PII** — No real names, emails, or user paths in code. The PII scanner enforces this.
- **Test new features** — Add unit or integration tests for any new functionality.
- **Security first** — No `shell: true` in spawns, no raw SQL, validate all inputs, escape HTML output.
- **Windows-compatible** — This project targets Windows 10/11. Use forward slashes in paths where possible, test PowerShell scripts on Windows.

### Commit Messages

Use concise, descriptive commit messages:
- `Fix keep-awake UInt32 overflow on PowerShell 5.1`
- `Add agent count indicator to dashboard submit panel`
- `Remove shell:true from worker spawn (command injection fix)`

### Security Issues

If you find a security vulnerability, please report it privately by opening a GitHub security advisory rather than a public issue.

## Project Structure

```
relay/          WebSocket relay server + HTTP API
worker/         Worker agent process
coordinator/    Task decomposition + load balancing
dashboard/      Single-page monitoring UI
lib/            Shared utilities (keep-awake, data-dir)
install/        Service installers, setup wizard, and Inno Setup build (inno/)
test/           Test suites
scripts/        Build and maintenance scripts
logo/           Logo images (branding)
docs/images/    Architecture diagrams
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
