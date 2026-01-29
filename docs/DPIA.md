# DPIA: Boardroom-Moltbot Deployment

**Document Status**: Complete
**Created**: 2026-01-29
**Last Updated**: 2026-01-29
**Approved By**: Brian Gallagher (BG)
**Next Review**: 2027-01-29 or upon significant architecture change

---

## 1. Executive Summary

**Product Name**: Boardroom (Multi-Tenant AI Executive System)
**Product Type**: Self-Hosted Docker Deployment / AI-Powered Executive Assistant Platform
**Purpose**: Multi-agent executive system providing AI support for human executives through specialized AI agents (AI CEO, AI COO, AI CTO, etc.)

**Data Subjects**:
- Human executives using the system (Brian, Natalie, Dan)
- Third-party contacts referenced in business communications
- Future: Additional team members or client organizations

**Risk Level**: Medium (AI processing of business data)

**Key Characteristics**:
- Self-hosted on Hetzner Cloud (German data center, GDPR compliant)
- Per-user isolated container architecture (network isolation)
- API keys managed at proxy layer (never exposed to AI models)
- Cloudflare Tunnel + Access for secure ingress with SSO
- Markdown-based documentation with Git version control
- Integration with external AI providers (Anthropic, OpenAI, OpenRouter)

---

## 2. Data Processing Overview

### 2.1 Data Collected

| Data Type | Purpose | Retention | Legal Basis |
|-----------|---------|-----------|-------------|
| User conversations with AI | Executive decision support | Indefinite (file-based logs) | Legitimate interest |
| AI agent task files | Task tracking and completion | Indefinite (Git history) | Legitimate interest |
| Executive documentation | Business context for AI | Indefinite | Legitimate interest |
| Server access logs | Security/debugging | 30 days | Legitimate interest |
| API usage metrics | Cost tracking | 90 days | Legitimate interest |
| Authentication tokens | Access control | Session-based | Legitimate interest |

### 2.2 AI Model Processing

| Provider | Purpose | Data Sent | DPA Status |
|----------|---------|-----------|------------|
| Anthropic (Claude) | Primary AI model | User prompts, context files | Standard Terms |
| OpenAI | Secondary AI model | User prompts, context files | DPA available |
| OpenRouter | AI model routing | User prompts, context files | Standard Terms |

**Critical**: AI providers receive conversation content for processing. Users should not include:
- Passwords or API keys (auto-stripped by proxy)
- Social Security numbers or national ID numbers
- Credit card numbers
- Protected health information (PHI)

### 2.3 Data NOT Collected

- No tracking cookies
- No behavioral analytics
- No personal browsing history
- No biometric data
- No location data

### 2.4 Third-Party Processors

| Processor | Purpose | Location | DPA Status |
|-----------|---------|----------|------------|
| Hetzner Cloud | VPS hosting | Germany (EU) | **TODO: Verify DPA** |
| Cloudflare | Tunnel/Access/DNS | Global (US HQ) | Standard DPA |
| Anthropic | AI model (Claude) | USA | Standard Terms |
| OpenAI | AI model (GPT) | USA | DPA available |
| OpenRouter | AI routing | USA | Standard Terms |
| GitHub | Version control | USA | DPA (Microsoft) |

---

## 3. Architecture Summary

```
User → Cloudflare Access (SSO) → Cloudflare Tunnel
         ↓
   [Per-User Container Pair]
   ┌─────────────────────────────┐
   │  User Network (Isolated)    │
   │  ┌─────────┐  ┌───────────┐ │
   │  │ Console │←→│ API Proxy │ │
   │  │ (no API │  │ (has API  │ │
   │  │  keys)  │  │  keys)    │ │
   │  └────┬────┘  └─────┬─────┘ │
   └───────┼─────────────┼───────┘
           │             │
           │             ↓
           │    [External AI APIs]
           │    Anthropic, OpenAI, OpenRouter
           │
           ↓
    [Persistent Storage]
    /data/logs/, /data/config/
```

**Security Architecture**:
- **Network Isolation**: Each user's containers run in isolated Docker networks
- **API Key Separation**: API keys stored only in proxy container, never exposed to AI
- **SSO Authentication**: Cloudflare Access with Google Workspace SSO
- **Prompt Injection Guard**: SLM-based detection before tool execution (planned)
- **API Key Stripping**: Keys auto-redacted from logs to `[REDACTED]`

---

## 4. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| AI model data breach (provider) | Low | High | Minimize PII, use reputable providers |
| Container escape | Very Low | High | Ubuntu LTS, regular patching, rootless Docker |
| API key exposure via prompts | Medium | High | Proxy-only key storage, auto-stripping |
| Prompt injection attack | Medium | Medium | SLM detection hook (planned), input validation |
| Cloudflare account compromise | Low | High | MFA, access reviews, minimal permissions |
| Hetzner infrastructure breach | Very Low | High | Encrypted storage, German data protection |
| Unauthorized admin access | Low | Medium | Cloudflare Access SSO, audit logs |
| Insider threat (key exfiltration) | Low | Medium | Proxy-only keys, network isolation |

**High-Risk Processing Identified**: Yes - AI processing of business-sensitive data

---

## 5. DPIA Necessity Assessment

Per GDPR Article 35, DPIA is required when processing is "likely to result in a high risk to the rights and freedoms of natural persons."

**Assessment**:
- [ ] Large-scale processing of special categories — **No** (limited users)
- [ ] Systematic monitoring of public areas — **No**
- [x] Automated decision-making with legal effects — **Partial** (AI recommendations, but humans decide)
- [ ] Large-scale profiling — **No**
- [ ] Processing children's data — **No**
- [x] Innovative technology with unknown risks — **Yes** (AI agents for executive decisions)

**Conclusion**: Full DPIA recommended due to innovative AI technology processing business-sensitive data.

---

## 6. Data Protection Measures

### 6.1 Technical Measures

- [x] HTTPS/TLS for all communications (Cloudflare Tunnel)
- [x] Network isolation between user containers
- [x] API keys separated from AI processing layer
- [x] Git version control for audit trail
- [x] Auto-redaction of API keys in logs
- [ ] Prompt injection detection (planned)
- [ ] File-based encrypted backups (planned)
- [x] Cloudflare DDoS protection

### 6.2 Organizational Measures

- [x] Human executives maintain decision authority
- [x] AI agents cannot commit without approval
- [x] Clear data handling documentation
- [x] Regular security reviews (quarterly)
- [ ] Staff training on AI data handling (N/A - internal use)
- [ ] Incident response plan documented (planned)

### 6.3 Data Subject Rights

| Right | Implementation |
|-------|----------------|
| Access | Export script (`./scripts/export-user-data.sh`) |
| Rectification | Manual editing of markdown files |
| Erasure | Delete script (`./scripts/delete-user-data.sh`) |
| Portability | JSON export format available |
| Objection | Human can disable AI processing |
| Restriction | Container can be stopped |

---

## 7. AI-Specific Safeguards

### 7.1 Human Oversight

- Human executives set strategic direction
- AI agents defer final decisions to humans
- All commits require human approval
- Daily standups surface issues for human review

### 7.2 Transparency

- AI responses clearly identified
- Thinking/reasoning visible in extended mode
- Tool calls logged with full context
- No hidden AI processing

### 7.3 Accuracy & Bias

- Multiple AI models available (diversification)
- Human review of AI recommendations
- Audit trail in Git for all changes
- Regular review of AI outputs

---

## 8. Compliance Checklist

- [x] Data minimization applied
- [x] Lawful basis documented (legitimate interest)
- [x] GDPR-compliant hosting (Hetzner Germany)
- [ ] DPA verified with Hetzner (TODO)
- [x] DPA with Cloudflare (standard)
- [x] AI provider terms reviewed
- [x] Access controls implemented
- [x] Audit logging enabled
- [x] Data export capability
- [x] Data deletion capability
- [ ] Cookie consent banner (N/A - no cookies)
- [ ] Privacy policy published (internal use only)

---

## 9. Conclusion

**Full DPIA Required**: Yes (completed in this document)

Boardroom-Moltbot is a medium-risk AI processing system. Key risk factors:
1. AI models process business-sensitive conversation data
2. Third-party AI providers (US-based) receive data
3. Innovative technology with evolving risk landscape

**Mitigations in place**:
1. GDPR-compliant EU hosting (Hetzner Germany)
2. Network isolation and API key separation
3. Human oversight of all AI actions
4. Comprehensive audit trail via Git
5. Auto-redaction of sensitive data

**Residual risks accepted**:
1. AI provider data processing (mitigated by terms review)
2. Potential prompt injection (mitigated by planned detection)
3. Container-level vulnerabilities (mitigated by patching policy)

---

## 10. Action Items

| Item | Owner | Due | Status |
|------|-------|-----|--------|
| Verify Hetzner DPA | Dan | 2026-01-31 | TODO |
| Document incident response plan | Brian | 2026-02-15 | TODO |
| Implement prompt injection guard | Dan | 2026-02-28 | Planned |
| Review AI provider terms quarterly | Natalie | 2026-04-01 | Scheduled |
| Encrypted backup implementation | Dan | 2026-03-15 | Planned |

---

## Related Documents

- [Implementation Plan](../plan/implementation-plan.md) (referenced via .claude/plans/)
- [DECISIONS.md](DECISIONS.md)
- [Boardroom Architecture](../../boardroom/projects/boardroom/architecture.md)
- [Boardroom Safety Policy](../../boardroom/projects/boardroom/safety-policy.md)

---

**Version History**

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-29 | BG/Claude | Initial complete DPIA |
