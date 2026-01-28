# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-01-28

### Added

- **Repository structure** - Initial project scaffolding with organized directories:
  - `/docker` - Container definitions and compose files
  - `/api-proxy` - Hono-based API proxy for key management
  - `/admin-ui` - Administrative interface for key and user management
  - `/scripts` - Automation and deployment scripts
  - `/tests` - Playwright E2E test suite
  - `/patches` - Branding replacement patches
  - `/plan` - Implementation planning documents
  - `/docs` - Project documentation

- **Docker containerization** - Ubuntu 24.04 LTS-based container design:
  - Full development toolchain support (Node.js/nvm, Python, Homebrew, Go)
  - Health check endpoints for orchestration
  - Configurable resource limits
  - Non-root user execution

- **API proxy for key isolation** - Secure architecture separating AI from credentials:
  - Console containers have NO access to API keys
  - Proxy container injects keys at request time
  - Auto-redaction of keys in chat logs (`[REDACTED]` replacement)
  - Admin-only key management interface

- **Multi-tenant architecture design** - Per-user container pair model:
  - Isolated Docker networks per user (`boardroom-{user}-network`)
  - Container naming convention (`boardroom-{user}-console`, `boardroom-{user}-proxy`)
  - Subdomain pattern (`{user}.lemalogic.boardroom.site`)
  - Network isolation preventing cross-user communication

- **Security hardening based on vulnerability research** - Mitigations for known attack vectors:
  - Authentication bypass prevention via network isolation
  - Prompt injection defense through key separation
  - Supply chain protection with curated skill allowlist
  - Plaintext secret elimination from console environment
  - Infostealer resistance via hardened container configuration
  - API key entry rejection at AI level

### Security

- Addressed critical vulnerabilities identified in security research:
  - [The Register: Moltbot Security Concerns](https://www.theregister.com/2026/01/27/clawdbot_moltbot_security_concerns/)
  - [Bitdefender: Exposed Control Panels](https://www.bitdefender.com/en-us/blog/hotforsecurity/moltbot-security-alert-exposed-clawdbot-control-panels-risk-credential-leaks-and-account-takeovers)
  - [InfoStealers: ClawdBot Primary Target](https://www.infostealers.com/article/clawdbot-the-new-primary-target-for-infostealers-in-the-ai-era/)

### Documentation

- Implementation plan with phased rollout strategy
- Architecture Decision Records (ADRs) in `/docs/DECISIONS.md`
- Security research references and mitigation mapping

---

## Version History

| Version | Date | Summary |
|---------|------|---------|
| 0.1.0 | 2026-01-28 | Initial architecture and security design |

[Unreleased]: https://github.com/LEMALogic/boardroom-moltbot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LEMALogic/boardroom-moltbot/releases/tag/v0.1.0
