# TODO - Boardroom Command Center

## Phase 1: Base Infrastructure (COMPLETE)

- [x] Create GitHub repo LEMALogic/boardroom-moltbot
- [x] Clone repo and set up basic directory structure
- [x] Create README.md, DECISIONS.md, CHANGELOG.md
- [x] Create Ubuntu-based Dockerfile.console with nvm, Python, Brew, Go
- [x] Create API proxy with Hono (routes for Anthropic/OpenAI with cost tracking)
- [x] Create docker-compose.yml with console + proxy services
- [x] Create Makefile with build/run/test commands
- [x] Create user provisioning scripts (create-user.sh, remove-user.sh)
- [x] Create Playwright test configuration
- [x] Configure gateway to bind to 0.0.0.0 for Docker port forwarding
- [x] Add `dangerouslyDisableDeviceAuth` for local dev (skip pairing requirement)
- [x] Build Control UI assets (`pnpm ui:build`)
- [x] Verify web console loads and connects (Health: OK)
- [x] Configure moltbot to route API calls through proxy (baseUrl config)
- [x] **End-to-end chat test successful** - Message sent, Anthropic responded via proxy

---

## Phase 2: API Proxy Integration

### High Priority

- [x] **Configure moltbot to route API calls through proxy** ✅ COMPLETE
  - Added `models.providers.anthropic.baseUrl` to moltbot config
  - Set to `http://proxy:8080/v1/anthropic`
  - Proxy injects `ANTHROPIC_API_KEY` before forwarding to Anthropic
  - End-to-end test successful: Chat message → Proxy → Anthropic API → Response

- [ ] **Complete API proxy admin UI**
  - Add key management interface (add/remove/rotate keys)
  - Add compliance notices (GDPR, DPIA warnings)
  - Add admin-only mode toggle
  - Add per-user key storage (for multi-tenant)

### Medium Priority

- [ ] **Auto-generate unique session per browser tab**
  - Currently defaults to `session=main` if not specified (all tabs share same conversation)
  - Options:
    1. Check if moltbot has config for auto-generating session IDs
    2. Create landing page that redirects with UUID: `/` → `/chat?session=<uuid>`
    3. Inject JavaScript that sets unique session on page load
  - Goal: Each new tab gets isolated conversation by default

- [ ] **Multi-session support within container**
  - Sessions already work via URL query param `?session=<id>`
  - Document session management for users
  - Consider session persistence across container restarts

## Phase 3: Multi-Tenant Docker Setup

- [ ] **Per-user isolated networks**
  - Create user provisioning that generates isolated Docker network per user
  - Update docker-compose.multi.yml with network isolation patterns
  - Test that containers can't communicate across user boundaries

- [ ] **Container pair orchestration**
  - Each user gets: console container + proxy container + isolated network
  - Shared cloudflared tunnel routing by subdomain
  - Health monitoring across all user containers

## Phase 4: Complete Rebranding

- [ ] **Remove all Moltbot/Clawdbot references**
  - UI title: "Moltbot Control" → "Boardroom Command Center"
  - Logo replacement
  - Environment variable prefixes: CLAWDBOT_* → BOARDROOM_*
  - Config paths: ~/.clawdbot → ~/.boardroom
  - Create comprehensive patch script

- [ ] **Apply Boardroom branding**
  - Custom theme colors
  - Logo assets
  - Custom assistant name/avatar

## Phase 5: Testing

- [ ] **Real LLM E2E tests**
  - Requires working proxy integration first
  - Test chat roundtrip with actual API call
  - Branding verification tests
  - API key rejection tests (AI can't add keys)

## Notes

### Current Access Points

| Service | URL |
|---------|-----|
| Web Console | http://localhost:18790 |
| SSH | `ssh -p 2222 boardroom@localhost` (password: boardroom) |
| API Proxy | http://localhost:8080 |
| Proxy Admin | http://localhost:8080/admin |

### Key Configuration Files

- `docker/Dockerfile.console` - Main container with moltbot
- `docker/docker-compose.yml` - Service orchestration
- `api-proxy/src/index.ts` - Hono proxy with cost tracking
- Container config: `/home/boardroom/.clawdbot-dev/moltbot.json`
