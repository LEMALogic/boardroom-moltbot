# Boardroom Command Center

Enterprise Multi-Tenant AI Assistant with security-hardened Docker deployment.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

Boardroom Command Center is an enterprise-grade, multi-tenant AI assistant platform based on Moltbot. It provides secure, isolated AI environments for each user with complete API key isolation - the AI never sees actual API keys, which are managed entirely at the proxy layer.

**Repository**: https://github.com/LEMALogic/boardroom-moltbot

### Key Features

- **Per-User Container Pairs** - Each user gets isolated console + api-proxy containers
- **API Key Isolation** - AI never sees actual keys; managed at proxy layer only
- **Network Isolation** - Users cannot communicate with other users' containers
- **Complete Rebranding** - All Clawdbot/Moltbot references removed; Boardroom Command Center branding
- **Cloudflare Tunnel** - Secure SSH and web access without exposing ports
- **Playwright E2E Tests** - Real LLM verification tests (no mocking)
- **Enterprise Compliance** - Admin-controlled API key management with GDPR/DPIA notices
- **Container Sleep** - Automatic sleep after 30 minutes idle (60-80% resource savings)

---

## Quick Start

### Prerequisites

- Docker or Rancher Desktop
- Make
- Node.js 20+ (for local development)

### Build and Run

```bash
# Clone the repository
git clone https://github.com/LEMALogic/boardroom-moltbot.git
cd boardroom-moltbot

# Build all containers
make build

# Start the stack
make run

# Access web console at http://localhost:18790
```

### Common Commands

```bash
make build          # Build all containers
make run            # Start stack
make stop           # Stop stack
make logs           # View log files
make shell          # SSH into console container
make test           # Run Playwright E2E tests (real LLM)
make test-all       # Run full test suite
```

---

## Architecture

### Per-User Container Pairs

Each user receives an isolated environment consisting of two containers on a private network:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HOST / ORCHESTRATOR                             │
│                                                                              │
│   User: Dan Thomas                        User: Brian Gallagher              │
│   ┌─────────────────────────────┐        ┌─────────────────────────────┐    │
│   │  lemalogic-dan-network      │        │  lemalogic-brian-network    │    │
│   │                             │        │                             │    │
│   │  ┌─────────┐  ┌──────────┐  │        │  ┌─────────┐  ┌──────────┐  │    │
│   │  │ lema-   │  │ lema-    │  │        │  │ lema-   │  │ lema-    │  │    │
│   │  │ dan-    │  │ dan-     │  │        │  │ brian-  │  │ brian-   │  │    │
│   │  │ console │◄─┤ proxy    │  │        │  │ console │◄─┤ proxy    │  │    │
│   │  │ NO KEYS │  │ HAS KEYS │  │        │  │ NO KEYS │  │ HAS KEYS │  │    │
│   │  └────┬────┘  └────┬─────┘  │        │  └────┬────┘  └────┬─────┘  │    │
│   │       │            │        │        │       │            │        │    │
│   └───────┼────────────┼────────┘        └───────┼────────────┼────────┘    │
│           │            │                         │            │             │
│   ┌───────┴────────────┴─────────────────────────┴────────────┴───────┐     │
│   │                      cloudflared (shared)                          │     │
│   │  lemalogic-dan.boardroom.site    lemalogic-brian.boardroom.site   │     │
│   └───────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                          ┌───────────┴───────────┐
                          │   External APIs       │
                          │ (Anthropic, OpenAI)   │
                          └───────────────────────┘
```

### Network Model

Each user gets an isolated Docker network with their own proxy:

- **Console Container** - User-facing AI assistant (NO API keys)
- **Proxy Container** - API key storage and injection (HAS API keys)
- **Network Isolation** - Containers cannot communicate across user networks

The console container:
- CAN access the internet directly (web searches, browsing, general HTTP)
- MUST route through proxy for API key-protected services (Anthropic, OpenAI)
- CANNOT communicate with other users' containers

### Container Naming Convention

```
{company}-{username}-console
{company}-{username}-proxy
{company}-{username}-network
```

Example for Brian at LEMA Logic:
- `lemalogic-brian-console` - Console container
- `lemalogic-brian-proxy` - Proxy container (has API keys)
- `lemalogic-brian-network` - Isolated Docker network

This naming groups containers by company when sorted alphabetically.

### URL Patterns

| User | Console URL | Gateway Token |
|------|-------------|---------------|
| Brian Gallagher | `lemalogic-brian.boardroom.site` | Required in URL or settings |
| Dan Thomas | `lemalogic-dan.boardroom.site` | Required in URL or settings |

**Access Pattern**: `https://{company}-{username}.boardroom.site/` (protected by Cloudflare Access SSO)

**SSH Access**: `ssh -p 2222 boardroom@{server-ip}` (Brian) or port 2223 (Dan)

---

## Security Features

### Mitigated Vulnerabilities

| Vulnerability | Severity | Mitigation |
|--------------|----------|------------|
| Authentication bypass (localhost auto-grant) | CRITICAL | Network isolation between container pairs |
| Exposed control panels | CRITICAL | Cloudflare Tunnel with SSO auth |
| Prompt injection (key extraction) | HIGH | API keys NEVER in console container |
| Supply chain exploits (malicious skills) | HIGH | Curated allowlist; admin-approved only |
| Plaintext secrets in files | HIGH | Secrets only in isolated proxy container |
| AI accepting new API keys | HIGH | Configured to reject API key entry |
| Infostealer targeting | MEDIUM | Ubuntu hardened container; no host filesystem access |

### Additional Security Measures

- **Prompt Injection Detection** - Pre-tool hook with SLM detection
- **API Key Redaction** - Auto-stripped and replaced with `[REDACTED]` in logs
- **48-Hour Patch Window** - For kernel/runtime CVEs
- **SSO Authentication** - Cloudflare Access integration
- **SSH Key Management** - Per-user SSH keys

### Residual Risks

| Risk | Status | Notes |
|------|--------|-------|
| Container escape CVEs | ONGOING | Requires 48-hour patch window |
| User session data | ACCEPTABLE | User owns container; needed for coherence |
| Cloudflare Tunnel compromise | LOW | Requires Cloudflare account breach |

---

## Configuration

### Environment Variables

Create a `.env` file based on `.env.example`:

```bash
cp .env.example .env
```

Key configuration options:

```env
# User Configuration
BOARDROOM_USER=demo
BOARDROOM_COMPANY=lemalogic

# API Keys (managed in proxy only)
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...

# Cloudflare Tunnel
CLOUDFLARE_TUNNEL_TOKEN=...

# Container Settings
IDLE_TIMEOUT_MINUTES=30
```

### Per-User Network Configuration

```yaml
# docker-compose.yml example
networks:
  lemalogic-dan-network:
    driver: bridge
  lemalogic-brian-network:
    driver: bridge
```

---

## Development

### Project Structure

```
boardroom-moltbot/
├── plan/
│   └── implementation-plan.md   # Detailed implementation plan
├── docker/
│   ├── console/                 # Console container (Ubuntu 24.04)
│   │   └── Dockerfile
│   └── proxy/                   # API proxy container (Hono-based)
│       └── Dockerfile
├── proxy/                       # Hono API proxy source
├── scripts/
│   ├── create-user.sh           # Create new user environment
│   ├── remove-user.sh           # Remove user environment
│   └── sleep-manager.sh         # Idle container management
├── tests/
│   └── e2e/                     # Playwright E2E tests
├── docker-compose.yml
├── Makefile
└── README.md
```

### Local Development

```bash
# Install dependencies
npm install

# Build containers
make build

# Run with hot reload (development)
make dev

# Run tests
make test
```

### Base Image

- **OS**: Ubuntu 24.04 LTS
- **Includes**: nvm, Python, Homebrew, Go
- **Rationale**: Better compatibility than Alpine for development tools

---

## User Provisioning

### Create a New User

```bash
# Usage: ./scripts/create-user.sh <company> <username> [--test] [--remote <ssh-host>]

# Local execution (on server)
./scripts/create-user.sh lemalogic alice
./scripts/create-user.sh lemalogic bob --test

# Remote execution using SSH config host name
./scripts/create-user.sh lemalogic alice --remote boardroom.prod
./scripts/create-user.sh acme carol --remote boardroom.prod --test
```

This creates:
- Isolated Docker network: `{company}-{username}-network`
- Proxy container with API keys: `{company}-{username}-proxy`
- Console container (no API keys): `{company}-{username}-console`
- Git-versioned data directories: `/home/boardroom/data/{company}-{username}-console` and `/home/boardroom/data/{company}-{username}-proxy`
- Auto-generated gateway token
- Moltbot config pointing to user's own proxy
- **OpenRouter API key** (if `OPENROUTER_PROVISIONING_KEY` is set) with $100/month default limit

### OpenRouter API Key Provisioning

When creating users, the script can automatically provision OpenRouter API keys:

```bash
# Set provisioning key (get from https://openrouter.ai/settings/provisioning-keys)
export OPENROUTER_PROVISIONING_KEY="sk-or-v1-..."

# Create user - OpenRouter key is auto-provisioned
./scripts/create-user.sh lemalogic alice --remote boardroom.prod
```

**Key naming**: `{company}-{username}-boardroom` (e.g., `lemalogic-alice-boardroom`)

**Features**:
- **Auto-create**: New key created with $100/month spending limit
- **Auto-reactivate**: If user is recreated, existing key is re-enabled
- **Auto-disable**: When user is removed, key is disabled (not deleted) for reactivation

**Check usage** via the proxy API:
```bash
# Get usage for default OpenRouter key
curl http://proxy:8080/admin/openrouter/usage

# Get usage for all OpenRouter aliases
curl http://proxy:8080/admin/openrouter/usage/all
```

### Remove a User

```bash
# Usage: ./scripts/remove-user.sh <company> <username> [--keep-data] [--force] [--remote <ssh-host>]

# Local execution
./scripts/remove-user.sh lemalogic alice
./scripts/remove-user.sh lemalogic alice --force --keep-data

# Remote execution using SSH config host name
./scripts/remove-user.sh lemalogic alice --remote boardroom.prod --force
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATA_BASE_DIR` | `/home/boardroom/data` | Base directory for user data |
| `CONSOLE_IMAGE` | `ghcr.io/lemalogic/boardroom-console:amd64` | Console Docker image |
| `PROXY_IMAGE` | `boardroom-api-proxy:latest` | Proxy Docker image |
| `OPENROUTER_PROVISIONING_KEY` | _(none)_ | OpenRouter provisioning key for auto API key creation |

### SSH Config Setup

For remote execution, add an entry to `~/.ssh/config`:

```
Host boardroom.prod
    HostName 46.224.211.238
    User root
    IdentityFile ~/.ssh/hetzner-boardroom
```

Then use `--remote boardroom.prod` with the scripts.

---

## Persistent Storage

Each user's entire home directory is persisted to the host filesystem and initialized as a git repository for version control.

### What Gets Persisted

The console container's `/home/boardroom/` is mounted to `/home/boardroom/data/{company}-{username}-console/` on the host:

| Directory | Contents | Versioned |
|-----------|----------|-----------|
| `.clawdbot-dev/` | Moltbot config, agents, history | ✅ Yes |
| `.clawdbot/` | Moltbot runtime data | ✅ Yes |
| `.moltbot/` | Moltbot data | ✅ Yes |
| `clawd/`, `clawd-dev/` | Project work directories | ✅ Yes |
| `.bashrc`, `.profile` | Shell customizations | ✅ Yes |
| `.cache/`, `.npm/`, `.nvm/` | Caches and runtime | ❌ No (gitignored) |

### Git Versioning

Each user's data directory is initialized as a git repository on creation, allowing:
- **History tracking** - See what changed and when
- **Rollback** - Restore previous configurations
- **Audit trail** - Track changes to agents and settings

### Managing Versions

```bash
# View history
cd /home/boardroom/data/lemalogic-brian-console
git log --oneline

# See recent changes
git diff HEAD~1

# Commit current state (manual checkpoint)
git add -A && git commit -m "Updated agent configuration"

# Rollback to previous state
git checkout HEAD~1 -- .clawdbot-dev/agents/
```

### Automatic Commits (Recommended)

Add a cron job to automatically commit changes daily:

```bash
# Add to crontab on host
0 2 * * * cd /home/boardroom/data/lemalogic-brian-console && git add -A && git commit -m "Daily auto-commit $(date +%Y-%m-%d)" 2>/dev/null || true
```

### Backup Strategy

Since data directories are git repositories, backup is straightforward:

```bash
# Push to remote (one-time setup)
cd /home/boardroom/data/lemalogic-brian-console
git remote add origin git@github.com:LEMALogic/boardroom-user-brian.git
git push -u origin main

# Automated backup via cron
0 3 * * * cd /home/boardroom/data/lemalogic-brian-console && git push origin main 2>/dev/null || true
```

### Rebuild Without Data Loss

Since data persists on the host, containers can be rebuilt without losing user data:

```bash
# Remove and recreate containers (data preserved)
./scripts/remove-user.sh lemalogic brian --keep-data
./scripts/create-user.sh lemalogic brian

# User's agents, history, and config are all restored
```

---

## Testing

### Playwright E2E Tests

Tests use real LLM verification - no mocking or skipping:

```bash
# Run all E2E tests
make test

# Run specific test file
npx playwright test tests/e2e/branding.spec.ts

# Run with UI
npx playwright test --ui
```

### Test Categories

1. **Branding Verification** - Confirms no Clawdbot/Moltbot/Molty references
2. **Real LLM Chat** - Sends messages, verifies coherent responses
3. **API Key Rejection** - Confirms AI rejects API key entry attempts
4. **Container Lifecycle** - Tests start, stop, sleep, wake cycles
5. **Network Isolation** - Verifies cross-container communication blocked

### Verification Checklist

- [ ] `make build` completes without errors
- [ ] `make run` starts containers and becomes healthy
- [ ] Web console loads at http://localhost:18789
- [ ] Page title shows "Boardroom Command Center"
- [ ] NO text contains Clawdbot/Moltbot/Molty
- [ ] Chat message receives coherent response
- [ ] Logs created in MD + JSON format
- [ ] API keys NOT present in console container
- [ ] Prompt injection detection rejects suspicious input
- [ ] `make test-all` passes

---

## Deployment

### Local Deployment

```bash
make build
make run
# Access at http://localhost:18789
```

### Hetzner Cloud Deployment

Recommended production hosting (GDPR compliant, best value at approximately 3.49 EUR/month):

1. **Provision Server**
   ```bash
   # Create Hetzner Cloud server (CX11 or CX21)
   # Install Docker and Docker Compose
   ```

2. **Configure Cloudflare Tunnel**
   ```bash
   # Install cloudflared
   cloudflared tunnel create boardroom

   # Configure tunnel for each user
   cloudflared tunnel route dns boardroom dan.lemalogic.boardroom.site
   cloudflared tunnel route dns boardroom brian.lemalogic.boardroom.site
   ```

3. **Deploy Stack**
   ```bash
   git clone https://github.com/LEMALogic/boardroom-moltbot.git
   cd boardroom-moltbot

   # Configure environment
   cp .env.example .env
   # Edit .env with production values

   # Deploy
   make build
   make run
   ```

4. **Configure Cloudflare Access** (SSO)

   The `create-user.sh` script automatically creates Access apps via API. Manual setup:

   ```bash
   # Get credentials
   CF_TOKEN=$(grep "^CLOUDFLARE_API_TOKEN=" /path/to/.env | cut -d'=' -f2)
   CF_ACCOUNT=$(grep "^CLOUDFLARE_ACCOUNT_ID=" /path/to/.env | cut -d'=' -f2)

   # Create Access Application
   curl -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/access/apps" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "name": "Boardroom - username",
       "domain": "lemalogic-username.boardroom.site",
       "type": "self_hosted",
       "session_duration": "24h"
     }'

   # Create policy (use app ID from response)
   curl -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/access/apps/{app_id}/policies" \
     -H "Authorization: Bearer $CF_TOKEN" \
     -H "Content-Type: application/json" \
     -d '{
       "name": "Allow user",
       "decision": "allow",
       "include": [{"email": {"email": "user@company.com"}}],
       "precedence": 1
     }'
   ```

   The `remove-user.sh` script automatically removes Access apps when deleting users.

### Scaling Guidelines

| Users | Recommended Orchestration |
|-------|--------------------------|
| < 25 | Docker Compose |
| 25-100 | Docker Swarm |
| 100+ | Kubernetes |

---

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Production hosting | Hetzner Cloud + Cloudflare Tunnel | Best value, full SSH, GDPR compliant |
| Local dev | Docker Compose + Rancher Desktop | Simple, no cloud costs |
| Base image | Ubuntu 24.04 LTS | Better compatibility; Brew/Go/nvm support |
| User authentication | SSO (web) + SSH keys (terminal) | Enterprise-grade |
| Chat logging | File-based (MD + JSON pairs) | Simple, grep-searchable |
| Container idle | Sleep after 30 min | 60-80% resource savings |
| Console network | Direct internet + proxy for APIs | Web searches direct; LLM via proxy |
| Orchestration | Docker Compose to Swarm | Simple until scaling requires more |

---

## Security References

- [The Register: Clawdbot becomes Moltbot security concerns](https://www.theregister.com/2026/01/27/clawdbot_moltbot_security_concerns/)
- [Bitdefender: Moltbot security alert](https://www.bitdefender.com/en-us/blog/hotforsecurity/moltbot-security-alert-exposed-clawdbot-control-panels-risk-credential-leaks-and-account-takeovers)
- [OWASP: LLM Prompt Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html)
- [Auth0: API Key Security for AI Agents](https://auth0.com/blog/api-key-security-for-ai-agents/)
- [Google Cloud: Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox)

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## Support

For issues and feature requests, please use the [GitHub Issues](https://github.com/LEMALogic/boardroom-moltbot/issues) page.
