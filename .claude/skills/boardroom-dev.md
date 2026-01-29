# Boardroom Development Best Practices

Use this skill when working on boardroom-moltbot development, container builds, or Hetzner deployment.

## Critical Rules

### 1. Build on Hetzner, Not Locally
- **ALWAYS** build Docker images on the Hetzner server, not locally
- Local builds are slow and architecture may differ (arm64 vs amd64)
- Use: `ssh boardroom.prod "cd /tmp/boardroom-build && docker build ..."`

### 2. Copy Files Before Rebuilding - ALWAYS
**Priority order for making changes (FASTEST to SLOWEST):**

1. **Copy built assets between containers** (seconds)
   ```bash
   # If Brian's container works, copy to Dan's - DON'T rebuild
   ssh boardroom.prod "docker cp lemalogic-brian-console:/app/moltbot/dist/control-ui/. /tmp/ui-copy/ && \
                       docker cp /tmp/ui-copy/. lemalogic-dan-console:/app/moltbot/dist/control-ui/"
   ssh boardroom.prod "docker restart lemalogic-dan-console"
   ```

2. **Copy source files between containers, then restart** (seconds)
   ```bash
   # Copy source file from working container to broken one
   ssh boardroom.prod "docker cp lemalogic-brian-console:/app/moltbot/ui/src/ui/app-render.ts /tmp/ && \
                       docker cp /tmp/app-render.ts lemalogic-dan-console:/app/moltbot/ui/src/ui/"
   ```

3. **Edit source in container + rebuild UI** (minutes) - only if source changes needed
   ```bash
   ssh boardroom.prod "docker exec -u boardroom lemalogic-brian-console bash"
   # Edit source files in /app/moltbot/ui/src/
   source ~/.nvm/nvm.sh && cd /app/moltbot && pnpm ui:build
   docker restart lemalogic-brian-console
   ```

4. **Rebuild Docker image** (many minutes) - LAST RESORT only

**CRITICAL:** If one container is working and another isn't, **COPY from the working one first**. Don't rebuild.

### 3. Don't Dismiss Failed Tests
- If a test fails, investigate and fix it
- Never skip tests to "save time"
- Use Playwright to verify UI changes actually work

### 4. Container UID Must Be 1000
- Host `boardroom` user is UID 1000
- Container user must also be UID 1000 for volume mounts to work
- If you see `EACCES: permission denied`, check UID mismatch

### 5. trustedProxies Must Be Exact IPs (NOT CIDR)
- Moltbot does **NOT** support CIDR notation in `trustedProxies`
- **WRONG:** `"trustedProxies": ["10.0.0.0/8"]`
- **RIGHT:** `"trustedProxies": ["10.100.0.1"]`
- If you see "Proxy headers detected from untrusted address", check this config

### 6. Docker Networks Use 10.* Subnets
- Brian's network: `10.100.0.0/24` (gateway: `10.100.0.1`)
- Dan's network: `10.101.0.0/24` (gateway: `10.101.0.1`)
- The gateway IP must match `trustedProxies` in moltbot config

## Key File Paths

### Inside Container
| Path | Purpose |
|------|---------|
| `/app/moltbot/ui/src/ui/app-render.ts` | Main UI rendering (header, branding) |
| `/app/moltbot/ui/src/ui/icons.ts` | SVG icons |
| `/app/moltbot/ui/index.html` | Page title |
| `/app/moltbot/dist/control-ui/` | Built UI assets |
| `/home/boardroom/.clawdbot-dev/moltbot.json` | Gateway config |

### On Host (Hetzner)
| Path | Purpose |
|------|---------|
| `/home/boardroom/data/{company}-{user}-console/` | Persistent user data |
| `/tmp/boardroom-build/` | Build directory |
| `/home/boardroom/.env` | Gateway tokens |

### Local Repo
| Path | Purpose |
|------|---------|
| `patches/apply-branding.sh` | Branding changes script |
| `docker/Dockerfile.console` | Console container definition |
| `docker/Dockerfile.proxy` | Proxy container definition |
| `scripts/create-user.sh` | User provisioning |
| `scripts/remove-user.sh` | User removal |

## Development Workflow

### Making UI Changes
1. SSH into the running container
2. Edit the source file (e.g., `app-render.ts`)
3. Rebuild UI: `pnpm ui:build`
4. Restart container: `docker restart <container>`
5. Test with Playwright
6. Once working, update `patches/apply-branding.sh`
7. Rebuild image for permanent change

### Syncing Changes to Hetzner
```bash
# Sync specific directories
rsync -avz patches/ boardroom.prod:/tmp/boardroom-build/patches/
rsync -avz docker/ boardroom.prod:/tmp/boardroom-build/docker/
```

### Building Images
```bash
# Build console image (use --no-cache if patches changed)
ssh boardroom.prod "cd /tmp/boardroom-build && docker build -t boardroom-console:latest -f docker/Dockerfile.console ."

# Build proxy image
ssh boardroom.prod "cd /tmp/boardroom-build && docker build -t boardroom-api-proxy:latest -f docker/Dockerfile.proxy ."
```

### Redeploying Containers
```bash
# Stop and remove
ssh boardroom.prod "docker stop lemalogic-brian-console && docker rm lemalogic-brian-console"

# Recreate with new image
ssh boardroom.prod "docker create \
    --name 'lemalogic-brian-console' \
    --network 'lemalogic-brian-network' \
    --restart unless-stopped \
    --publish '2222:22' \
    --publish '19001:19001' \
    --volume '/home/boardroom/data/lemalogic-brian-console:/home/boardroom:rw' \
    --env 'CLAWDBOT_GATEWAY_TOKEN=<token>' \
    'boardroom-console:latest'"

# Start
ssh boardroom.prod "docker start lemalogic-brian-console"
```

## Testing

### Playwright Testing
```bash
# Navigate and check
mcp__playwright__browser_navigate to URL with token
mcp__playwright__browser_wait_for 5 seconds (WebSocket needs time)
mcp__playwright__browser_snapshot to check elements
mcp__playwright__browser_take_screenshot for visual verification
```

### Common Issues

#### "device identity required" Error
This error has multiple causes:

1. **Wrong token** - Verify URL token matches `CLAWDBOT_GATEWAY_TOKEN` env var:
   ```bash
   docker exec <container> printenv CLAWDBOT_GATEWAY_TOKEN
   ```

2. **trustedProxies misconfigured** - Check for "Proxy headers detected from untrusted address" in logs:
   - Moltbot does NOT support CIDR notation
   - Must use exact gateway IP: `"trustedProxies": ["10.100.0.1"]`

3. **Missing config flags** - Ensure both are set:
   ```json
   "controlUi": {
     "dangerouslyDisableDeviceAuth": true,
     "allowInsecureAuth": true
   }
   ```

4. **WebSocket timing** - Wait 3-5 seconds for connection to establish

#### Blank Page / Broken Layout
- Check browser console for JavaScript errors
- Likely a syntax error in patched TypeScript
- Rebuild UI inside container to see error messages

#### Permission Denied
- Check container user UID matches host user UID (both should be 1000)
- Check volume mount ownership: `ls -la /home/boardroom/data/`

## Gateway Configuration

The gateway config at `/home/boardroom/.clawdbot-dev/moltbot.json` should have:

```json
{
  "gateway": {
    "bind": "lan",
    "port": 19001,
    "mode": "local",
    "trustedProxies": ["10.100.0.1"],
    "controlUi": {
      "dangerouslyDisableDeviceAuth": true,
      "allowInsecureAuth": true
    },
    "auth": {}
  }
}
```

**CRITICAL:**
- `trustedProxies` must contain the **exact** Docker gateway IP (e.g., `10.100.0.1`)
- Moltbot does NOT support CIDR notation - only exact IP addresses work
- Token authentication is disabled via `patches/disable-token-auth.sh` - no `?token=` URL parameter needed
- Access is secured via Cloudflare Tunnel with SSO instead

## Branding Changes

The `patches/apply-branding.sh` script makes these changes:
- `MOLTBOT` → `BOARDROOM` (header)
- Subtitle shows user email from `BOARDROOM_USER_EMAIL` env var (falls back to "Boardroom Dashboard")
- `Moltbot Control` → `Boardroom` (page title)
- Removes lobster logo

### User Email in Header
The header displays the user's email (e.g., "brian@lemalogic.com") below "BOARDROOM".
- Set via `BOARDROOM_USER_EMAIL` env var when creating container
- Injected at container startup by `patches/inject-user-email.sh`
- Use `--email` flag with `create-user.sh`: `./create-user.sh lemalogic bob --email bob@lemalogic.com`

To add features (like logout button), modify `/app/moltbot/ui/src/ui/app-render.ts` in the container first, test, then update the patch script.

## Container Naming

Format: `{company}-{username}-{role}`

Examples:
- `lemalogic-brian-console`
- `lemalogic-brian-proxy`
- `lemalogic-dan-console`

## Ports

| User | SSH Port | Gateway Port |
|------|----------|--------------|
| Brian | 2222 | 19001 |
| Dan | 2223 | 19002 |

## Access URLs

- Brian: `https://lemalogic-brian.boardroom.site/`
- Dan: `https://lemalogic-dan.boardroom.site/`

**Note:** No `?token=` needed - authentication is via Cloudflare Access SSO.

## Cloudflare Access Configuration

Each user has a Cloudflare Access application protecting their dashboard:

| User | Access App ID | Domain | Allowed Email |
|------|---------------|--------|---------------|
| Brian | `13d5330a-124b-4a96-bc94-701774dbf591` | lemalogic-brian.boardroom.site | brian@lemalogic.com |
| Dan | `dbd1a554-00de-465b-aa7d-cf886d946c28` | lemalogic-dan.boardroom.site | dan@lemalogic.com |

### Creating Access App for New User
```bash
# Get credentials from .env
CF_TOKEN=$(grep "^CLOUDFLARE_API_TOKEN=" /Users/brian/Sites/github/boardroom/.env | cut -d'=' -f2)
CF_ACCOUNT=$(grep "^CLOUDFLARE_ACCOUNT_ID=" /Users/brian/Sites/github/boardroom/.env | cut -d'=' -f2)

# Create Access Application
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/access/apps" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Boardroom - <username>",
    "domain": "lemalogic-<username>.boardroom.site",
    "type": "self_hosted",
    "session_duration": "24h"
  }' | jq .

# Note the app ID from response, then create policy
APP_ID="<app-id-from-response>"
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/access/apps/$APP_ID/policies" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Allow <username>",
    "decision": "allow",
    "include": [{"email": {"email": "<user>@lemalogic.com"}}],
    "precedence": 1
  }' | jq .
```

### Listing Access Apps
```bash
curl -s "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/access/apps" \
  -H "Authorization: Bearer $CF_TOKEN" | jq '.result[] | {id, name, domain}'
```

### Deleting Access App
```bash
curl -s -X DELETE "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT/access/apps/<app-id>" \
  -H "Authorization: Bearer $CF_TOKEN"
```

## Docker Network Management

### Current Network Configuration
| User | Network | Subnet | Gateway |
|------|---------|--------|---------|
| Brian | lemalogic-brian-network | 10.100.0.0/24 | 10.100.0.1 |
| Dan | lemalogic-dan-network | 10.101.0.0/24 | 10.101.0.1 |

### Creating a New User Network
```bash
# Create network with 10.* subnet
docker network create --subnet=10.102.0.0/24 --gateway=10.102.0.1 lemalogic-newuser-network
```

### Checking Network Configuration
```bash
# View network details
docker network inspect lemalogic-brian-network --format '{{range .IPAM.Config}}Subnet: {{.Subnet}}, Gateway: {{.Gateway}}{{end}}'

# List container IPs
docker inspect <container> --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```
