# Boardroom-Moltbot: Enterprise Multi-Tenant AI Assistant

## Executive Summary

Create a **multi-tenant, security-hardened Docker deployment** for Moltbot with:
- **Per-user container pairs** (console + api-proxy) with network isolation
- **API key isolation** - AI never sees actual keys; managed at proxy layer
- **No tokens needed** - Container pairs communicate only with each other
- **SSH/Console access** via Cloudflare Tunnel per user
- **Playwright E2E tests** with real LLM verification (tests must pass, never skip)
- **Complete rebranding** - Remove ALL Clawdbot/Moltbot/Molty references
- **Enterprise compliance** - Admin-controlled API key management with GDPR/DPIA notices

---

## Critical Security Concerns Identified

### Known Vulnerabilities (from security research)

| Vulnerability | Severity | Our Mitigation |
|--------------|----------|----------------|
| **Authentication bypass** - Localhost connections auto-granted behind reverse proxy | CRITICAL | Network isolation between container pairs; no shared auth tokens |
| **Exposed control panels** - Hundreds found with API keys/chat history exposed | CRITICAL | Cloudflare Tunnel with auth; no public exposure |
| **Prompt injection** - 5-minute private key extraction demonstrated | HIGH | API keys NEVER in console container; proxy-only storage |
| **Supply chain exploit** - Skills can execute arbitrary code | HIGH | Curated allowlist; admin-approved skills only |
| **Plaintext secrets** - Files contain credentials | HIGH | Secrets only in isolated api-proxy container |
| **Infostealer targeting** - Malware targeting moltbot directories | MEDIUM | Ubuntu hardened container; no host filesystem access |
| **AI accepting new API keys** | HIGH | Moltbot configured to reject API key entry; proxy-only management |

### Unmitigated/Residual Risks

| Risk | Status | Notes |
|------|--------|-------|
| **Prompt injection** | MITIGATED | Pre-tool hook with SLM detection |
| **Container escape CVEs** | ONGOING | Requires 48-hour patch window for kernel/runtime CVEs |
| **User session data in container** | ACCEPTABLE | User owns container; needed for conversation coherence |
| **Cloudflare Tunnel compromise** | LOW | Requires Cloudflare account breach |
| **API keys in chat logs** | MITIGATED | Auto-stripped and replaced with `[REDACTED]` |

### Sources
- [The Register: Clawdbot becomes Moltbot security concerns](https://www.theregister.com/2026/01/27/clawdbot_moltbot_security_concerns/)
- [Bitdefender: Moltbot security alert](https://www.bitdefender.com/en-us/blog/hotforsecurity/moltbot-security-alert-exposed-clawdbot-control-panels-risk-credential-leaks-and-account-takeovers)
- [InfoStealers: ClawdBot primary target](https://www.infostealers.com/article/clawdbot-the-new-primary-target-for-infostealers-in-the-ai-era/)
- [OWASP: LLM Prompt Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/LLM_Prompt_Injection_Prevention_Cheat_Sheet.html)
- [Auth0: API Key Security for AI Agents](https://auth0.com/blog/api-key-security-for-ai-agents/)
- [Google Cloud: Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox)

---

## Multi-Tenant Architecture

### Per-User Container Pairs

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              HOST / ORCHESTRATOR                             │
│                                                                              │
│   User: Dan Thomas                        User: Brian Gallagher              │
│   ┌─────────────────────────────┐        ┌─────────────────────────────┐    │
│   │  dan-network (isolated)     │        │  brian-network (isolated)   │    │
│   │                             │        │                             │    │
│   │  ┌─────────┐  ┌──────────┐  │        │  ┌─────────┐  ┌──────────┐  │    │
│   │  │ dan-    │  │ dan-     │  │        │  │ brian-  │  │ brian-   │  │    │
│   │  │ console │◄─┤ proxy    │  │        │  │ console │◄─┤ proxy    │  │    │
│   │  │         │  │          │  │        │  │         │  │          │  │    │
│   │  │ NO KEYS │  │ HAS KEYS │  │        │  │ NO KEYS │  │ HAS KEYS │  │    │
│   │  └────┬────┘  └────┬─────┘  │        │  └────┬────┘  └────┬─────┘  │    │
│   │       │            │        │        │       │            │        │    │
│   └───────┼────────────┼────────┘        └───────┼────────────┼────────┘    │
│           │            │                         │            │             │
│   ┌───────┴────────────┴─────────────────────────┴────────────┴───────┐     │
│   │                      cloudflared (shared)                          │     │
│   │  dan.lemalogic.boardroom.site    brian.lemalogic.boardroom.site   │     │
│   └───────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                          ┌───────────┴───────────┐
                          │   External APIs       │
                          │ (Anthropic, OpenAI)   │
                          └───────────────────────┘
```

### Network Model

Each user gets an **isolated Docker network** with their own proxy. The console container:
- **CAN** access the internet directly (for web searches, browsing, general HTTP)
- **MUST** route through proxy for API key-protected services (Anthropic, OpenAI, etc.)
- **CANNOT** communicate with other users' containers

```yaml
# Per-user network isolation (NOT internal - allows internet)
networks:
  dan-network:
    driver: bridge
  brian-network:
    driver: bridge
```

**Security benefit**: API keys remain isolated in proxy container. Even if AI extracts all environment variables from console, there are no API keys to find. Direct internet access enables web search, browsing, and other agent capabilities.

---

## Naming Convention

### Per-User Subdomains

| User | Console URL | SSH Host |
|------|-------------|----------|
| Dan Thomas | `dan.lemalogic.boardroom.site` | `ssh.dan.lemalogic.boardroom.site` |
| Brian Gallagher | `brian.lemalogic.boardroom.site` | `ssh.brian.lemalogic.boardroom.site` |
| Generic/Demo | `demo.lemalogic.boardroom.site` | `ssh.demo.lemalogic.boardroom.site` |

**Pattern**: `{username}.{company}.boardroom.site`

### Container Naming

```
boardroom-{username}-console
boardroom-{username}-proxy
boardroom-{username}-network
```

---

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **Production hosting** | Hetzner Cloud + Cloudflare Tunnel | Best value (€3.49/mo), full SSH, GDPR compliant |
| **Local dev** | Docker Compose + Rancher Desktop | Simple, no cloud costs, full control |
| **Base image** | Ubuntu 24.04 LTS | Better compatibility than Alpine; Brew/Go/nvm support |
| **User authentication** | SSO (web) + SSH keys (terminal) | Enterprise-grade; Cloudflare Access integration |
| **Chat logging** | File-based (MD + JSON pairs) | Simple, searchable with grep; no SQL needed |
| **Container idle** | Sleep after 30 min | 60-80% resource savings |
| **Cost controls** | Admin approval for high usage | Prevents runaway costs; configurable thresholds |
| **Domain pattern** | `{user}.lemalogic.boardroom.site` | Wildcard DNS; company-specific |
| **Console network access** | Direct internet + proxy for APIs | Web searches direct; LLM calls via proxy for key injection |
| **Web console access** | Cloudflare Tunnel + Access SSO | Accessible from anywhere on internet with SSO auth |
| **Cloudflare Containers** | Not feasible | R2 FUSE latency (50-200ms) unsuitable; researched Jan 2026 |
| **Orchestration** | Docker Compose (<25 users), Swarm (25-100) | Simple until scaling requires more |

---

## Implementation Phases

### Phase 1: Repository & Base Infrastructure
1. Create GitHub repo `LEMALogic/boardroom-moltbot`
2. Clone to `~/Sites/github/boardroom-moltbot`
3. Save this plan to `/plan/implementation-plan.md`
4. Create README.md, DECISIONS.md, CHANGELOG.md
5. Set up basic directory structure
6. Create Ubuntu-based Dockerfile for console (with nvm, Python, Brew, Go)

### Phase 2: API Proxy with Key Management
1. Build Hono-based proxy
2. Create admin UI for key management
3. Add compliance notices
4. Implement admin-only mode flag
5. Configure per-user key storage

### Phase 3: Multi-Tenant Docker Setup
1. Create user provisioning scripts
2. Implement per-user isolated networks
3. Configure container pairing
4. Set up shared cloudflared tunnel

### Phase 4: Complete Rebranding
1. Create comprehensive patch script
2. Remove ALL Clawdbot/Moltbot/Molty references
3. Apply Boardroom Command Center branding
4. Patch API key rejection

### Phase 5: Testing (Real LLM Required)
1. Playwright config (no skipping)
2. Branding verification tests
3. Real LLM chat tests
4. API key rejection tests
5. Container lifecycle tests

### Phase 6: Documentation
1. DECISIONS.md with security references
2. SECURITY.md architecture doc
3. DEPLOYMENT.md guide
4. CHANGELOG.md

### Phase 7: Cloudflare Tunnel + Authentication
1. Setup script for per-user tunnels
2. DNS configuration for boardroom.site
3. Cloudflare Access SSO configuration
4. SSH key management per user

### Phase 8: File-Based Logging System
1. Implement log capture in console entrypoint (MD + JSON files)
2. Create log viewer page in admin UI (file-based search)
3. Add export/deletion scripts for GDPR
4. Document log format and search patterns

### Phase 9: Container Orchestration
1. Implement sleep-manager.sh for idle detection
2. Configure wake-on-request via Cloudflare
3. Add cost tracking middleware to proxy
4. Build admin dashboard for cost management
5. Create user provisioning automation

### Phase 10: DPIA & Compliance Documentation
1. Create DPIA (Data Protection Impact Assessment) document
2. Create privacy notice template for users
3. Document data retention and deletion procedures
4. Create incident response plan template

---

## Verification Plan

### Local Testing Checklist
1. [ ] `make build` completes without errors
2. [ ] `make run` starts containers and becomes healthy
3. [ ] Web console loads at http://localhost:18789
4. [ ] Page title shows "Boardroom Command Center"
5. [ ] NO text contains Clawdbot/Moltbot/Molty
6. [ ] Send chat message, receive coherent response
7. [ ] Verify logs created in MD + JSON format
8. [ ] Verify API keys NOT in console container
9. [ ] Test prompt injection detection rejects suspicious input
10. [ ] `make test-all` passes (real LLM tests)

### E2E Test Commands
```bash
make build          # Build all containers
make run            # Start stack
make test           # Run Playwright E2E (real LLM)
make logs           # Check log files created
make shell          # SSH into container
make stop           # Stop stack
```

---

## Environment Notes

- **Container Runtime**: Rancher Desktop (Docker-compatible)
- **Host OS**: macOS Darwin 25.2.0
- **Target Base**: Ubuntu 24.04 LTS
