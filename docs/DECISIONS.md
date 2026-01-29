# Architecture Decision Records (ADRs)

This document captures all significant architecture decisions for Boardroom-Moltbot with rationale, alternatives considered, and security research references.

---

## Table of Contents

1. [ADR-001: Ubuntu 24.04 LTS as Base Image](#adr-001-ubuntu-2404-lts-as-base-image)
2. [ADR-002: Per-User Container Pairs Architecture](#adr-002-per-user-container-pairs-architecture)
3. [ADR-003: API Keys in Proxy Only](#adr-003-api-keys-in-proxy-only)
4. [ADR-004: Hetzner Cloud for Production Hosting](#adr-004-hetzner-cloud-for-production-hosting)
5. [ADR-005: Cloudflare Tunnel for Access](#adr-005-cloudflare-tunnel-for-access)
6. [ADR-006: File-Based Logging](#adr-006-file-based-logging)
7. [ADR-007: Real LLM Tests Required](#adr-007-real-llm-tests-required)
8. [ADR-008: No Gateway Token with Cloudflare Access](#adr-008-no-gateway-token-with-cloudflare-access)

---

## ADR-001: Ubuntu 24.04 LTS as Base Image

**Status**: Accepted
**Date**: 2026-01-28

### Context

We need a container base image that supports the full development toolchain required by Moltbot, including:
- Node.js via nvm
- Python with pip
- Homebrew (for macOS-native tools)
- Go compiler
- Git and standard Unix utilities

### Decision

Use **Ubuntu 24.04 LTS** as the base image for console containers.

### Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| **Alpine Linux** | Tiny image (~5MB), fast builds | musl libc breaks many npm packages; no native Brew support; nvm/pyenv issues |
| **Debian Slim** | Small, stable, glibc | Missing many packages; requires manual setup for dev tools |
| **Ubuntu 22.04** | Stable, well-tested | Older packages; Python 3.10 vs 3.12 |

### Rationale

1. **Full glibc compatibility** - Many npm native modules and Python packages assume glibc, causing cryptic failures on Alpine's musl
2. **Homebrew support** - Ubuntu is the only non-macOS platform officially supported by Homebrew for Linux
3. **LTS lifecycle** - Ubuntu 24.04 supported until April 2029 (security fixes until 2034)
4. **Developer familiarity** - Most developers are comfortable with Ubuntu/Debian package management
5. **Pre-built binaries** - Node, Python, Go all provide official Ubuntu binaries

### Consequences

- Larger base image (~70MB compressed vs ~5MB for Alpine)
- Slightly slower CI builds (acceptable tradeoff)
- Must apply regular security updates

---

## ADR-002: Per-User Container Pairs Architecture

**Status**: Accepted
**Date**: 2026-01-28

### Context

Security research has identified critical vulnerabilities in single-tenant AI assistant deployments:
- Authentication bypass via localhost trust behind reverse proxies
- Prompt injection attacks extracting API keys in under 5 minutes
- Hundreds of exposed control panels with chat history and credentials visible

### Decision

Deploy **isolated container pairs per user**, each with their own dedicated proxy:
- `{user}-lemalogic-console` - The AI assistant environment (NO API keys)
- `{user}-lemalogic-proxy` - API key management and request routing (HAS keys)
- `{user}-network` - Isolated Docker network connecting only the user's pair

**Critical**: Each user has their own proxy container. This prevents:
- Cross-user API key access
- Request/response logging visibility between users
- Any shared state that could leak information

### Architecture

```
User: Dan                              User: Brian
┌─────────────────────────┐           ┌─────────────────────────┐
│  dan-network (isolated) │           │ brian-network (isolated)│
│  ┌─────────┐ ┌────────┐ │           │ ┌─────────┐ ┌────────┐  │
│  │ console │◄┤ proxy  │ │           │ │ console │◄┤ proxy  │  │
│  │ NO KEYS │ │HAS KEYS│ │           │ │ NO KEYS │ │HAS KEYS│  │
│  └─────────┘ └────────┘ │           │ └─────────┘ └────────┘  │
└─────────────────────────┘           └─────────────────────────┘
```

### Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| **Shared multi-tenant** | Lower resource usage | Single breach exposes all users |
| **Kubernetes pods** | Industry standard | Overkill for <25 users; complexity |
| **VM per user** | Strongest isolation | 10x resource overhead; slow startup |

### Rationale

1. **Blast radius containment** - Compromise of one user's container cannot access another user's keys or data
2. **Network isolation** - Docker networks prevent cross-user communication at the network layer
3. **Key separation** - Even if AI is tricked into dumping environment variables, no keys exist in the console container
4. **Auditability** - Per-user containers enable clear logging attribution

### Security Research References

- [The Register: Moltbot Security Concerns (2026-01-27)](https://www.theregister.com/2026/01/27/clawdbot_moltbot_security_concerns/) - Documents authentication bypass vulnerabilities
- [Bitdefender: Exposed Control Panels](https://www.bitdefender.com/en-us/blog/hotforsecurity/moltbot-security-alert-exposed-clawdbot-control-panels-risk-credential-leaks-and-account-takeovers) - Hundreds of exposed instances with credentials
- [Google Cloud: Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox) - Google's approach to AI agent isolation

### Consequences

- Higher resource usage (~2x containers per user)
- More complex orchestration
- Requires user provisioning automation

---

## ADR-003: API Keys in Proxy Only

**Status**: Accepted
**Date**: 2026-01-28

### Context

Prompt injection attacks against AI assistants can extract secrets in under 5 minutes. Demonstrated attacks include:
- Social engineering the AI to reveal environment variables
- Tricking the AI into executing code that reads config files
- Using tool-calling features to exfiltrate data

### Decision

**API keys are NEVER stored in the console container.** All API keys are:
1. Stored exclusively in the `api-proxy` container
2. Injected into requests at the proxy layer
3. Managed by administrators through a separate admin UI
4. Auto-stripped from chat logs with `[REDACTED]` replacement

The console container is configured to:
- Reject any attempt to input API keys
- Route all LLM API calls through the proxy
- Have direct internet access for non-API operations (web search, browsing)

### Threat Model

| Attack Vector | Without Mitigation | With Proxy Isolation |
|---------------|-------------------|---------------------|
| Prompt injection extracts env vars | API keys exposed | No keys to extract |
| Malicious skill reads config files | Keys in plaintext files | Files contain no keys |
| AI tricked into `printenv` | Keys visible | Empty/safe output |
| Container escape | Keys accessible | Must escape to different container |

### Security Research References

- [InfoStealers: ClawdBot Primary Target](https://www.infostealers.com/article/clawdbot-the-new-primary-target-for-infostealers-in-the-ai-era/) - Malware specifically targeting AI assistant directories
- [OWASP: LLM Prompt Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html) - Industry guidance on preventing injection attacks
- [Auth0: API Key Security for AI Agents](https://auth0.com/blog/api-key-security-for-ai-agents/) - Best practices for key management in AI systems

### Consequences

- Additional network hop for LLM requests (~5-10ms latency)
- Requires admin intervention for key rotation
- Users cannot self-service API key management (by design)

---

## ADR-004: Hetzner Cloud for Production Hosting

**Status**: Accepted
**Date**: 2026-01-28

### Context

Need a production hosting environment that provides:
- Full SSH access for container management
- GDPR compliance for EU customers
- Cost-effective scaling for multi-tenant deployment
- Reliable uptime and network connectivity

### Decision

Use **Hetzner Cloud** for production hosting.

### Alternatives Considered

| Provider | Monthly Cost | Pros | Cons |
|----------|-------------|------|------|
| **Hetzner Cloud CX22** | €3.49 | GDPR, full SSH, excellent value | EU-only datacenters |
| **AWS EC2 t3.micro** | ~$8.50 | Global presence, ecosystem | Complex networking, higher cost |
| **DigitalOcean Basic** | $6.00 | Simple, good docs | No EU GDPR certification |
| **Cloudflare Containers** | Variable | Edge deployment | R2 FUSE latency (50-200ms) unsuitable |

### Rationale

1. **Best value** - CX22 (2 vCPU, 4GB RAM) at €3.49/month is exceptional value
2. **GDPR compliance** - German company with EU datacenters; compliant by design
3. **Full root access** - Unlike some managed services, full SSH and container control
4. **Predictable pricing** - No surprise egress charges or hidden fees
5. **IPv6 included** - Native dual-stack networking

### Cloudflare Containers Evaluation

We specifically evaluated Cloudflare's new container offering (researched January 2026) but found:
- R2 FUSE mount latency of 50-200ms per file operation
- Unsuitable for development workflows requiring fast filesystem access
- May reconsider when latency improves

### Consequences

- Limited to EU datacenters (acceptable for LEMA Logic's target market)
- Must manage our own security updates
- Need Cloudflare Tunnel for global access

---

## ADR-005: Cloudflare Tunnel for Access

**Status**: Accepted
**Date**: 2026-01-28

### Context

Users need secure access to their console containers from anywhere on the internet, without exposing containers directly to the public internet.

### Decision

Use **Cloudflare Tunnel** with **Cloudflare Access** for all external access:
- Web console: `{user}.lemalogic.boardroom.site`
- SSH access: `ssh.{user}.lemalogic.boardroom.site`
- Authentication via Cloudflare Access SSO

### Architecture

```
User Browser/Terminal
        │
        ▼
┌───────────────────┐
│ Cloudflare Access │  ← SSO Authentication
│   (Zero Trust)    │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Cloudflare Tunnel │  ← Encrypted tunnel
│   (cloudflared)   │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│  User's Console   │  ← No public IP exposed
│    Container      │
└───────────────────┘
```

### Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| **Direct port exposure** | Simple | Security nightmare; DDoS target |
| **VPN (WireGuard)** | Strong encryption | Requires client software; complex |
| **Tailscale** | Easy mesh VPN | Per-seat pricing adds up |
| **ngrok** | Simple tunnels | Expensive at scale; no SSO |

### Rationale

1. **Zero public exposure** - Containers have no public IP; only Cloudflare can reach them
2. **Built-in SSO** - Cloudflare Access integrates with Google/GitHub/OIDC
3. **DDoS protection** - Cloudflare absorbs attacks before they reach infrastructure
4. **Wildcard DNS** - Single `*.lemalogic.boardroom.site` certificate covers all users
5. **Free tier** - Up to 50 users on Cloudflare Access free tier

### Security Research References

- [Bitdefender: Exposed Control Panels](https://www.bitdefender.com/en-us/blog/hotforsecurity/moltbot-security-alert-exposed-clawdbot-control-panels-risk-credential-leaks-and-account-takeovers) - Why public exposure is dangerous

### Consequences

- Dependency on Cloudflare availability
- Requires Cloudflare account management
- Small latency overhead (~10-30ms)

---

## ADR-006: File-Based Logging

**Status**: Accepted
**Date**: 2026-01-28

### Context

Need to log chat interactions for:
- Debugging and support
- Usage analytics
- GDPR compliance (data export/deletion)
- Audit trail

### Decision

Use **file-based logging** with paired Markdown and JSON files:
- `{timestamp}-{session}.md` - Human-readable chat transcript
- `{timestamp}-{session}.json` - Structured metadata for programmatic access

### Directory Structure

```
/logs/{username}/
  2026-01-28-a1b2c3.md
  2026-01-28-a1b2c3.json
  2026-01-28-d4e5f6.md
  2026-01-28-d4e5f6.json
```

### Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| **SQLite** | Structured queries | Adds dependency; overkill for logs |
| **PostgreSQL** | Powerful queries | Infrastructure overhead; connection management |
| **Elasticsearch** | Full-text search | Heavy resource usage; complex |
| **CloudWatch/Datadog** | Managed service | Cost at scale; vendor lock-in |

### Rationale

1. **Simplicity** - No database to manage, backup, or secure
2. **Grep-friendly** - Full-text search with standard Unix tools
3. **GDPR compliance** - Easy deletion: `rm /logs/{username}/*`
4. **Export ready** - Files are the export format; no conversion needed
5. **Audit friendly** - Immutable files with timestamps
6. **Per-user isolation** - User's logs stay in their container

### Consequences

- No complex queries (acceptable for this use case)
- Must implement log rotation
- Search limited to grep/ripgrep capabilities

---

## ADR-007: Real LLM Tests Required

**Status**: Accepted
**Date**: 2026-01-28

### Context

AI assistant behavior is non-deterministic and depends on:
- Model version and fine-tuning
- System prompts and context
- Tool availability and configuration
- Branding patches applied correctly

Mock tests cannot verify that:
- The AI actually responds coherently
- Branding replacement works in real conversations
- API key rejection is enforced at the AI level

### Decision

**All E2E tests MUST use real LLM API calls.** Tests are configured to:
- Never skip due to API unavailability
- Fail if no valid API key is provided
- Verify actual AI responses, not mocked data

### Test Categories

| Test Type | Real LLM Required | Purpose |
|-----------|------------------|---------|
| Branding verification | Yes | Confirm no Clawdbot/Moltbot in responses |
| Chat coherence | Yes | AI responds meaningfully |
| API key rejection | Yes | AI refuses to accept new keys |
| Container lifecycle | No | Start/stop/health checks |
| Network isolation | No | Cross-container communication blocked |

### Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| **Mock all LLM calls** | Fast, deterministic, free | Doesn't test real behavior |
| **Record/replay** | Faster than live | Stale when model updates |
| **Hybrid (mock + real)** | Balance of speed/accuracy | Complexity; which to mock? |

### Rationale

1. **Behavioral verification** - Only real calls prove the AI behaves correctly
2. **Model updates** - Claude/GPT updates can change behavior; must test against current model
3. **Branding confidence** - Patches might miss edge cases only visible in real conversations
4. **Security validation** - API key rejection must be tested against actual AI reasoning

### Consequences

- Tests require valid API key in CI environment
- Tests cost money (typically <$0.10 per run)
- Tests are slower (~30s for LLM responses)
- Tests may flake due to model non-determinism (mitigated with retries)

---

## ADR-008: No Gateway Token with Cloudflare Access

**Status**: Accepted
**Date**: 2026-01-28

### Context

Moltbot's Control UI has a built-in "gateway token" authentication mechanism that requires users to enter a secret token to connect to the websocket. This is designed for scenarios where the gateway is exposed directly or through basic reverse proxies.

### Decision

**Disable gateway token authentication** since Cloudflare Access provides superior authentication:
- Set `dangerouslyDisableDeviceAuth: true`
- Set `allowInsecureAuth: true`

### Architecture with Cloudflare Access

```
User Browser
      │
      ▼ (1) Google SSO login
┌─────────────────────┐
│  Cloudflare Access  │  ← Identity verified here
└─────────────────────┘
      │
      ▼ (2) JWT cookie set
┌─────────────────────┐
│  Cloudflare Tunnel  │  ← Only authenticated users reach here
└─────────────────────┘
      │
      ▼ (3) Already authenticated
┌─────────────────────┐
│   Moltbot Gateway   │  ← No additional token needed
└─────────────────────┘
```

### Why Gateway Token Adds No Value

| Scenario | Without Cloudflare Access | With Cloudflare Access |
|----------|--------------------------|----------------------|
| Unauthenticated user tries to connect | Token blocks them | Cloudflare blocks them first |
| Authenticated user connects | Must enter token manually | Direct access (better UX) |
| Attacker bypasses Cloudflare | Token provides defense | If they bypass CF, they likely have container access anyway |

The gateway token protects against a scenario where someone:
1. Bypasses Cloudflare Tunnel AND Access (extremely difficult)
2. BUT cannot read environment variables from the container (unlikely if step 1 succeeded)

This is defense-in-depth for an implausible attack path while degrading UX for legitimate users.

### Alternatives Considered

| Alternative | Pros | Cons |
|-------------|------|------|
| **Keep gateway token** | Extra authentication layer | Redundant with CF Access; bad UX |
| **Auto-inject token via Cloudflare** | Best of both | Complex; CF Access is sufficient |
| **Remove token (chosen)** | Simple; great UX | Slightly reduced defense-in-depth |

### Rationale

1. **Cloudflare Access is the authentication boundary** - SSO verification before users can reach the gateway
2. **Zero public exposure** - Containers are only accessible via Cloudflare Tunnel
3. **UX improvement** - Users don't need to copy/paste tokens after already logging in via SSO
4. **Principle of least friction** - Security should be invisible when possible

### Consequences

- Slightly reduced defense-in-depth (acceptable given Cloudflare Access)
- Simpler user experience
- Cleaner architecture (single auth boundary)

---

## References

### Security Research

- [The Register: Moltbot Security Concerns](https://www.theregister.com/2026/01/27/clawdbot_moltbot_security_concerns/)
- [Bitdefender: Exposed Control Panels](https://www.bitdefender.com/en-us/blog/hotforsecurity/moltbot-security-alert-exposed-clawdbot-control-panels-risk-credential-leaks-and-account-takeovers)
- [InfoStealers: ClawdBot Primary Target](https://www.infostealers.com/article/clawdbot-the-new-primary-target-for-infostealers-in-the-ai-era/)
- [OWASP: LLM Prompt Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html)
- [Auth0: API Key Security for AI Agents](https://auth0.com/blog/api-key-security-for-ai-agents/)
- [Google Cloud: Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox)

### Vendor Documentation

- [Ubuntu 24.04 LTS Release Notes](https://wiki.ubuntu.com/NobleNumbat/ReleaseNotes)
- [Hetzner Cloud Documentation](https://docs.hetzner.com/cloud/)
- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflare Access Documentation](https://developers.cloudflare.com/cloudflare-one/policies/access/)
