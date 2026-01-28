import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import { logger } from 'hono/logger';
import { cors } from 'hono/cors';
import { timing } from 'hono/timing';
import Proxy from 'http-mitm-proxy';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { existsSync, mkdirSync, readFileSync, writeFileSync, watchFile } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// =============================================================================
// KEY STORAGE - Hot-reloadable from JSON file
// =============================================================================

const DATA_DIR = process.env.DATA_DIR || '/data';
const KEYS_FILE = join(DATA_DIR, 'api-keys.json');

interface StoredProvider {
  host: string;
  name: string;
  authHeader: string;
  authPrefix?: string;  // e.g., "Bearer " for Authorization header
  apiKey: string;
  extraHeaders?: Record<string, string>;
  enabled: boolean;
  addedAt: string;
  lastUsed?: string;
}

interface KeysStore {
  providers: StoredProvider[];
  version: number;
}

// =============================================================================
// ADMIN CONFIG - Controls what services are allowed and usage limits
// =============================================================================

interface AdminConfig {
  // Which providers users are allowed to add keys for (empty = all allowed)
  allowedServices: string[];
  // Daily usage caps per provider (in USD, 0 = unlimited)
  usageCaps: Record<string, number>;
  // Global daily cap across all providers (0 = unlimited)
  globalDailyCap: number;
  // Whether to require admin approval for new keys
  requireKeyApproval: boolean;
}

const ADMIN_CONFIG_FILE = join(DATA_DIR, 'admin-config.json');

let adminConfig: AdminConfig = {
  allowedServices: [], // Empty = all providers allowed
  usageCaps: {},
  globalDailyCap: 0,
  requireKeyApproval: false,
};

function loadAdminConfig(): AdminConfig {
  ensureDataDir();
  if (existsSync(ADMIN_CONFIG_FILE)) {
    try {
      return JSON.parse(readFileSync(ADMIN_CONFIG_FILE, 'utf-8'));
    } catch (err) {
      console.error('[ADMIN] Error loading config:', err);
    }
  }
  return adminConfig;
}

function saveAdminConfig(config: AdminConfig) {
  ensureDataDir();
  writeFileSync(ADMIN_CONFIG_FILE, JSON.stringify(config, null, 2));
  console.log('[ADMIN] Saved config to', ADMIN_CONFIG_FILE);
}

adminConfig = loadAdminConfig();

// Watch for config changes
if (existsSync(ADMIN_CONFIG_FILE)) {
  watchFile(ADMIN_CONFIG_FILE, { interval: 1000 }, () => {
    console.log('[ADMIN] Detected config changes, reloading...');
    adminConfig = loadAdminConfig();
  });
}

// =============================================================================
// KEY REDACTION PATTERNS - For chat log sanitization
// =============================================================================

const API_KEY_PATTERNS: { name: string; pattern: RegExp }[] = [
  { name: 'Anthropic', pattern: /sk-ant-api\d{2}-[A-Za-z0-9_-]{86,}/g },
  { name: 'OpenAI', pattern: /sk-[A-Za-z0-9]{20,}/g },
  { name: 'OpenRouter', pattern: /sk-or-v1-[A-Za-z0-9]{64}/g },
  { name: 'ElevenLabs', pattern: /xi-[A-Za-z0-9]{32}/g },
  { name: 'Google AI', pattern: /AIza[A-Za-z0-9_-]{35}/g },
  { name: 'Replicate', pattern: /r8_[A-Za-z0-9]{37}/g },
  { name: 'Hugging Face', pattern: /hf_[A-Za-z0-9]{34}/g },
  { name: 'Cohere', pattern: /[A-Za-z0-9]{40}(?=.*cohere)/gi },
  { name: 'Generic Long Key', pattern: /(?:key|token|secret|api[_-]?key)\s*[:=]\s*['"]?([A-Za-z0-9_-]{20,})['"]?/gi },
];

function redactApiKeys(text: string): { redacted: string; found: string[] } {
  let redacted = text;
  const found: string[] = [];

  for (const { name, pattern } of API_KEY_PATTERNS) {
    const matches = text.match(pattern);
    if (matches) {
      for (const match of matches) {
        found.push(`${name}: ${match.substring(0, 8)}...${match.slice(-4)}`);
        redacted = redacted.replace(match, `[REDACTED:${name.toUpperCase().replace(' ', '_')}_KEY]`);
      }
    }
  }

  return { redacted, found };
}

// Default provider templates (no keys - just the config structure)
const PROVIDER_TEMPLATES: Omit<StoredProvider, 'apiKey' | 'enabled' | 'addedAt'>[] = [
  { host: 'api.anthropic.com', name: 'Anthropic', authHeader: 'x-api-key', extraHeaders: { 'anthropic-version': '2023-06-01' } },
  { host: 'api.openai.com', name: 'OpenAI', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'generativelanguage.googleapis.com', name: 'Google AI', authHeader: 'x-goog-api-key' },
  { host: 'api.mistral.ai', name: 'Mistral', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.cohere.ai', name: 'Cohere', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.groq.com', name: 'Groq', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.perplexity.ai', name: 'Perplexity', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.together.xyz', name: 'Together AI', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.fireworks.ai', name: 'Fireworks', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api-inference.huggingface.co', name: 'Hugging Face', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.replicate.com', name: 'Replicate', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.ideogram.ai', name: 'Ideogram', authHeader: 'Api-Key' },
  { host: 'api.stability.ai', name: 'Stability AI', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.elevenlabs.io', name: 'ElevenLabs', authHeader: 'xi-api-key' },
  { host: 'api.retellai.com', name: 'Retell AI', authHeader: 'Authorization', authPrefix: 'Bearer ' },
  { host: 'api.resend.com', name: 'Resend', authHeader: 'Authorization', authPrefix: 'Bearer ' },
];

// In-memory store (loaded from file, hot-reloaded on changes)
let keysStore: KeysStore = { providers: [], version: 1 };

function ensureDataDir() {
  if (!existsSync(DATA_DIR)) {
    mkdirSync(DATA_DIR, { recursive: true });
  }
}

function loadKeysFromFile(): KeysStore {
  ensureDataDir();

  if (existsSync(KEYS_FILE)) {
    try {
      const data = readFileSync(KEYS_FILE, 'utf-8');
      const store = JSON.parse(data) as KeysStore;
      console.log(`[KEYS] Loaded ${store.providers.filter(p => p.enabled).length} active providers from ${KEYS_FILE}`);
      return store;
    } catch (err) {
      console.error(`[KEYS] Error loading keys file:`, err);
    }
  }

  // Initialize from environment variables if no file exists
  return initializeFromEnv();
}

function initializeFromEnv(): KeysStore {
  const envMapping: Record<string, string> = {
    'api.anthropic.com': 'ANTHROPIC_API_KEY',
    'api.openai.com': 'OPENAI_API_KEY',
    'generativelanguage.googleapis.com': 'GOOGLE_AI_API_KEY',
    'api.mistral.ai': 'MISTRAL_API_KEY',
    'api.cohere.ai': 'COHERE_API_KEY',
    'api.groq.com': 'GROQ_API_KEY',
    'api.perplexity.ai': 'PERPLEXITY_API_KEY',
    'api.together.xyz': 'TOGETHER_API_KEY',
    'api.fireworks.ai': 'FIREWORKS_API_KEY',
    'api-inference.huggingface.co': 'HUGGINGFACE_API_KEY',
    'api.replicate.com': 'REPLICATE_API_TOKEN',
    'api.ideogram.ai': 'IDEOGRAM_API_KEY',
    'api.stability.ai': 'STABILITY_API_KEY',
    'api.elevenlabs.io': 'ELEVENLABS_API_KEY',
    'api.retellai.com': 'RETELL_API_KEY',
    'api.resend.com': 'RESEND_API_KEY',
  };

  const providers: StoredProvider[] = PROVIDER_TEMPLATES.map(template => {
    const envVar = envMapping[template.host];
    const apiKey = envVar ? process.env[envVar] || '' : '';
    return {
      ...template,
      apiKey,
      enabled: !!apiKey,
      addedAt: new Date().toISOString(),
    };
  });

  const store: KeysStore = { providers, version: 1 };

  // Save to file for future use
  saveKeysToFile(store);

  return store;
}

function saveKeysToFile(store: KeysStore) {
  ensureDataDir();
  try {
    writeFileSync(KEYS_FILE, JSON.stringify(store, null, 2));
    console.log(`[KEYS] Saved ${store.providers.length} providers to ${KEYS_FILE}`);
  } catch (err) {
    console.error(`[KEYS] Error saving keys file:`, err);
  }
}

function getActiveProviders(): Map<string, StoredProvider> {
  const map = new Map<string, StoredProvider>();
  for (const provider of keysStore.providers) {
    if (provider.enabled && provider.apiKey) {
      map.set(provider.host, provider);
    }
  }
  return map;
}

// Load keys on startup
keysStore = loadKeysFromFile();

// Watch for file changes and hot-reload
if (existsSync(KEYS_FILE)) {
  watchFile(KEYS_FILE, { interval: 1000 }, () => {
    console.log(`[KEYS] Detected changes to ${KEYS_FILE}, reloading...`);
    keysStore = loadKeysFromFile();
  });
}

// Types
interface CostTrackingData {
  timestamp: string;
  provider: 'anthropic' | 'openai';
  path: string;
  method: string;
  inputTokens?: number;
  outputTokens?: number;
  model?: string;
  estimatedCost?: number;
  clientId?: string;
}

interface ProxyConfig {
  anthropicApiKey: string;
  openaiApiKey: string;
  port: number;
  proxyPort: number;
}

// Configuration
const config: ProxyConfig = {
  anthropicApiKey: process.env.ANTHROPIC_API_KEY || '',
  openaiApiKey: process.env.OPENAI_API_KEY || '',
  port: parseInt(process.env.PORT || '8080', 10),
  proxyPort: parseInt(process.env.PROXY_PORT || '3128', 10),
};

// Ensure certs directory exists
const certsDir = join(__dirname, '..', 'certs', '.http-mitm-proxy');
if (!existsSync(certsDir)) {
  mkdirSync(certsDir, { recursive: true });
}

// Cost tracking storage (in-memory for now, would be replaced with DB)
const costLog: CostTrackingData[] = [];

// Log configured providers at startup
const activeProviders = getActiveProviders();
console.log(`[CONFIG] Active API providers: ${Array.from(activeProviders.keys()).join(', ') || 'none'}`);


// Utility: Strip API keys from headers for logging (exported for potential use in logging middleware)
export function sanitizeHeaders(headers: Headers | Record<string, string>): Record<string, string> {
  const sanitized: Record<string, string> = {};
  const entries = headers instanceof Headers
    ? Array.from(headers.entries())
    : Object.entries(headers);

  for (const [key, value] of entries) {
    const lowerKey = key.toLowerCase();
    if (
      lowerKey.includes('authorization') ||
      lowerKey.includes('api-key') ||
      lowerKey.includes('x-api-key')
    ) {
      sanitized[key] = '[REDACTED]';
    } else {
      sanitized[key] = value;
    }
  }
  return sanitized;
}

// Utility: Estimate cost based on token usage
function estimateCost(
  provider: 'anthropic' | 'openai',
  model: string | undefined,
  inputTokens: number,
  outputTokens: number
): number {
  const anthropicRates: Record<string, { input: number; output: number }> = {
    'claude-3-opus': { input: 15, output: 75 },
    'claude-3-sonnet': { input: 3, output: 15 },
    'claude-3-haiku': { input: 0.25, output: 1.25 },
    'claude-3-5-sonnet': { input: 3, output: 15 },
  };

  const openaiRates: Record<string, { input: number; output: number }> = {
    'gpt-4-turbo': { input: 10, output: 30 },
    'gpt-4': { input: 30, output: 60 },
    'gpt-3.5-turbo': { input: 0.5, output: 1.5 },
    'gpt-4o': { input: 5, output: 15 },
  };

  const rates = provider === 'anthropic' ? anthropicRates : openaiRates;
  const defaultRate = provider === 'anthropic'
    ? { input: 3, output: 15 }
    : { input: 5, output: 15 };

  let rate = defaultRate;
  if (model) {
    for (const [key, value] of Object.entries(rates)) {
      if (model.includes(key)) {
        rate = value;
        break;
      }
    }
  }

  return (inputTokens * rate.input + outputTokens * rate.output) / 1_000_000;
}

// Cost tracking middleware
const trackCost = async (
  provider: 'anthropic' | 'openai',
  path: string,
  method: string,
  requestBody: unknown,
  responseBody: unknown
) => {
  const entry: CostTrackingData = {
    timestamp: new Date().toISOString(),
    provider,
    path,
    method,
  };

  if (responseBody && typeof responseBody === 'object') {
    const resp = responseBody as Record<string, unknown>;

    if (resp.usage && typeof resp.usage === 'object') {
      const usage = resp.usage as Record<string, number>;
      entry.inputTokens = usage.input_tokens || usage.prompt_tokens;
      entry.outputTokens = usage.output_tokens || usage.completion_tokens;
    }

    if (requestBody && typeof requestBody === 'object') {
      const req = requestBody as Record<string, unknown>;
      entry.model = req.model as string | undefined;
    }
    if (resp.model) {
      entry.model = resp.model as string;
    }
  }

  if (entry.inputTokens && entry.outputTokens) {
    entry.estimatedCost = estimateCost(
      provider,
      entry.model,
      entry.inputTokens,
      entry.outputTokens
    );
  }

  costLog.push(entry);

  if (costLog.length > 10000) {
    costLog.splice(0, costLog.length - 10000);
  }
};

// =============================================================================
// HONO APP - Direct API endpoints and admin UI
// =============================================================================

const app = new Hono();

app.use('*', cors());
app.use('*', timing());
app.use('*', logger());

// Health check
app.get('/health', (c) => {
  return c.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    hasAnthropicKey: !!config.anthropicApiKey,
    hasOpenaiKey: !!config.openaiApiKey,
  });
});

// Admin UI - Full key management interface
app.get('/admin', (c) => {
  const providers = keysStore.providers;
  const activeCount = providers.filter(p => p.enabled && p.apiKey).length;

  return c.html(`
    <!DOCTYPE html>
    <html>
    <head>
      <title>Boardroom API Proxy - Admin</title>
      <style>
        * { box-sizing: border-box; }
        body { font-family: system-ui, sans-serif; max-width: 1000px; margin: 0 auto; padding: 20px; background: #0a0a0a; color: #e0e0e0; }
        h1 { color: #fff; margin-bottom: 5px; }
        .subtitle { color: #888; margin-bottom: 30px; }
        .card { background: #1a1a1a; padding: 20px; border-radius: 8px; margin: 20px 0; border: 1px solid #333; }
        .card h2 { margin-top: 0; color: #fff; display: flex; align-items: center; gap: 10px; }
        .badge { background: #333; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: normal; }
        .badge.active { background: #1a3d1a; color: #4ade80; }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: left; padding: 12px; border-bottom: 2px solid #333; color: #888; font-weight: 500; }
        td { padding: 12px; border-bottom: 1px solid #222; }
        .status { display: inline-block; padding: 4px 12px; border-radius: 4px; font-weight: 500; font-size: 12px; }
        .status.active { background: #1a3d1a; color: #4ade80; }
        .status.inactive { background: #3d3d1a; color: #facc15; }
        .status.missing { background: #2d2d2d; color: #888; }
        code { background: #333; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
        input[type="text"], input[type="password"] {
          background: #222; border: 1px solid #444; color: #fff; padding: 8px 12px;
          border-radius: 4px; width: 100%; font-family: monospace;
        }
        input:focus { outline: none; border-color: #667eea; }
        button {
          background: #667eea; color: #fff; border: none; padding: 8px 16px;
          border-radius: 4px; cursor: pointer; font-weight: 500;
        }
        button:hover { background: #5a6fd6; }
        button.secondary { background: #333; }
        button.secondary:hover { background: #444; }
        button.danger { background: #dc2626; }
        button.danger:hover { background: #b91c1c; }
        .actions { display: flex; gap: 8px; }
        .key-input { display: flex; gap: 8px; align-items: center; }
        .key-input input { flex: 1; }
        .toggle {
          width: 44px; height: 24px; background: #333; border-radius: 12px;
          position: relative; cursor: pointer; transition: background 0.2s;
        }
        .toggle.on { background: #4ade80; }
        .toggle::after {
          content: ''; position: absolute; width: 20px; height: 20px;
          background: #fff; border-radius: 50%; top: 2px; left: 2px;
          transition: left 0.2s;
        }
        .toggle.on::after { left: 22px; }
        .warning { background: #3d2a1a; border: 1px solid #f59e0b; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
        .warning h3 { color: #f59e0b; margin: 0 0 10px 0; font-size: 14px; }
        .warning p { margin: 0; font-size: 13px; color: #d4a574; }
        .stats { display: flex; gap: 20px; margin-bottom: 20px; }
        .stat { background: #16213e; padding: 15px 25px; border-radius: 8px; text-align: center; }
        .stat .number { font-size: 28px; font-weight: bold; color: #667eea; }
        .stat .label { font-size: 12px; color: #888; margin-top: 5px; }
        a { color: #60a5fa; }
        .masked { font-family: monospace; color: #888; }
      </style>
    </head>
    <body>
      <h1>🏢 Boardroom API Proxy</h1>
      <p class="subtitle">API Key Management Console</p>

      <div class="warning">
        <h3>⚠️ Compliance Notice</h3>
        <p>Adding new AI services may require security assessment, GDPR compliance review,
        Data Processing Agreement (DPA), or Data Protection Impact Assessment (DPIA).
        Contact your IT/Security team before adding new providers.</p>
      </div>

      <div class="stats">
        <div class="stat">
          <div class="number">${activeCount}</div>
          <div class="label">Active Providers</div>
        </div>
        <div class="stat">
          <div class="number">${providers.length}</div>
          <div class="label">Total Configured</div>
        </div>
        <div class="stat">
          <div class="number">${costLog.length}</div>
          <div class="label">Requests Logged</div>
        </div>
        <div class="stat">
          <div class="number">$${costLog.reduce((sum, e) => sum + (e.estimatedCost || 0), 0).toFixed(2)}</div>
          <div class="label">Est. Total Cost</div>
        </div>
      </div>

      <div class="card">
        <h2>API Providers <span class="badge active">${activeCount} active</span></h2>
        <table>
          <thead>
            <tr>
              <th>Provider</th>
              <th>Host</th>
              <th>API Key</th>
              <th>Status</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            ${providers.map((p, i) => `
              <tr data-index="${i}">
                <td><strong>${p.name}</strong></td>
                <td><code>${p.host}</code></td>
                <td>
                  <span class="masked">${p.apiKey ? p.apiKey.substring(0, 8) + '...' + p.apiKey.slice(-4) : '(not set)'}</span>
                </td>
                <td>
                  <span class="status ${p.enabled && p.apiKey ? 'active' : p.apiKey ? 'inactive' : 'missing'}">
                    ${p.enabled && p.apiKey ? '✓ Active' : p.apiKey ? '⏸ Disabled' : '○ No Key'}
                  </span>
                </td>
                <td class="actions">
                  <button class="secondary" onclick="editKey(${i})">Edit</button>
                  <button class="secondary" onclick="toggleEnabled(${i})">${p.enabled ? 'Disable' : 'Enable'}</button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>

      <div class="card">
        <h2>Proxy Configuration</h2>
        <table>
          <tr><td>Admin Port</td><td><code>${config.port}</code></td></tr>
          <tr><td>MITM Proxy Port</td><td><code>${config.proxyPort}</code></td></tr>
          <tr><td>Keys File</td><td><code>${KEYS_FILE}</code></td></tr>
          <tr><td>Console Config</td><td><code>HTTP_PROXY=http://proxy:${config.proxyPort}</code></td></tr>
        </table>
      </div>

      <div class="card">
        <h2>Cost Tracking</h2>
        <p><a href="/admin/costs">View detailed cost data (JSON)</a></p>
      </div>

      <div class="card">
        <h2>Admin Controls</h2>
        <p style="color:#888; margin-bottom:15px;">Configure which services users can add and usage limits.</p>

        <div style="margin-bottom:20px;">
          <label style="display:block; margin-bottom:5px; color:#888;">Allowed Services (comma-separated, empty = all)</label>
          <input type="text" id="allowed-services" value="${adminConfig.allowedServices.join(', ')}"
            placeholder="e.g., anthropic, openai, google" style="margin-bottom:10px;">
          <p style="font-size:12px; color:#666;">Only these providers can have keys added via console chat.</p>
        </div>

        <div style="margin-bottom:20px;">
          <label style="display:block; margin-bottom:5px; color:#888;">Global Daily Cap (USD, 0 = unlimited)</label>
          <input type="number" id="global-cap" value="${adminConfig.globalDailyCap}" min="0" step="1"
            style="width:150px;">
        </div>

        <div style="margin-bottom:20px;">
          <label style="display:flex; align-items:center; gap:10px; cursor:pointer;">
            <input type="checkbox" id="require-approval" ${adminConfig.requireKeyApproval ? 'checked' : ''}
              style="width:18px; height:18px;">
            <span>Require admin approval for new keys</span>
          </label>
          <p style="font-size:12px; color:#666; margin-top:5px;">Keys added via console will be disabled until approved in this UI.</p>
        </div>

        <button onclick="saveConfig()">Save Admin Config</button>
      </div>

      <div class="card">
        <h2>Console API Reference</h2>
        <p style="color:#888; margin-bottom:15px;">Endpoints for console chat key management:</p>
        <table>
          <tr><td><code>POST /v1/keys/:provider</code></td><td>Add key: <code>{"key": "sk-..."}</code></td></tr>
          <tr><td><code>DELETE /v1/keys/:provider</code></td><td>Remove key for provider</td></tr>
          <tr><td><code>GET /v1/keys</code></td><td>List all providers and key status</td></tr>
          <tr><td><code>POST /v1/redact</code></td><td>Redact keys from text: <code>{"text": "..."}</code></td></tr>
        </table>
        <p style="margin-top:15px; font-size:13px; color:#888;">
          Example: User types "Add my Anthropic key sk-ant-..." → Console calls <code>POST /v1/keys/anthropic</code>
          → Immediately redacts key in chat display
        </p>
      </div>

      <!-- Edit Modal -->
      <div id="modal" style="display:none; position:fixed; top:0; left:0; right:0; bottom:0; background:rgba(0,0,0,0.8); z-index:1000; justify-content:center; align-items:center;">
        <div style="background:#1a1a1a; padding:30px; border-radius:8px; width:500px; border:1px solid #333;">
          <h3 style="margin-top:0; color:#fff;">Edit API Key</h3>
          <p id="modal-provider" style="color:#888;"></p>
          <div class="key-input" style="margin: 20px 0;">
            <input type="password" id="modal-key" placeholder="Enter API key...">
            <button class="secondary" onclick="toggleKeyVisibility()">Show</button>
          </div>
          <div style="display:flex; gap:10px; justify-content:flex-end;">
            <button class="secondary" onclick="closeModal()">Cancel</button>
            <button onclick="saveKey()">Save Key</button>
          </div>
        </div>
      </div>

      <script>
        let editingIndex = -1;

        function editKey(index) {
          editingIndex = index;
          const provider = ${JSON.stringify(providers)}[index];
          document.getElementById('modal-provider').textContent = provider.name + ' (' + provider.host + ')';
          document.getElementById('modal-key').value = provider.apiKey || '';
          document.getElementById('modal').style.display = 'flex';
        }

        function closeModal() {
          document.getElementById('modal').style.display = 'none';
          editingIndex = -1;
        }

        function toggleKeyVisibility() {
          const input = document.getElementById('modal-key');
          input.type = input.type === 'password' ? 'text' : 'password';
        }

        async function saveKey() {
          const apiKey = document.getElementById('modal-key').value;
          const res = await fetch('/admin/api/keys/' + editingIndex, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ apiKey })
          });
          if (res.ok) {
            location.reload();
          } else {
            alert('Failed to save key');
          }
        }

        async function toggleEnabled(index) {
          const res = await fetch('/admin/api/keys/' + index + '/toggle', { method: 'POST' });
          if (res.ok) {
            location.reload();
          }
        }

        async function saveConfig() {
          const allowedRaw = document.getElementById('allowed-services').value;
          const allowedServices = allowedRaw.trim()
            ? allowedRaw.split(',').map(s => s.trim()).filter(s => s)
            : [];

          const config = {
            allowedServices,
            globalDailyCap: parseFloat(document.getElementById('global-cap').value) || 0,
            requireKeyApproval: document.getElementById('require-approval').checked,
          };

          const res = await fetch('/admin/api/config', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(config)
          });

          if (res.ok) {
            alert('Config saved!');
            location.reload();
          } else {
            alert('Failed to save config');
          }
        }
      </script>
    </body>
    </html>
  `);
});

// API endpoints for key management
app.put('/admin/api/keys/:index', async (c) => {
  const index = parseInt(c.req.param('index'));
  const body = await c.req.json() as { apiKey: string };

  if (index < 0 || index >= keysStore.providers.length) {
    return c.json({ error: 'Invalid index' }, 400);
  }

  keysStore.providers[index].apiKey = body.apiKey;
  keysStore.providers[index].enabled = !!body.apiKey;
  keysStore.version++;
  saveKeysToFile(keysStore);

  return c.json({ success: true });
});

app.post('/admin/api/keys/:index/toggle', async (c) => {
  const index = parseInt(c.req.param('index'));

  if (index < 0 || index >= keysStore.providers.length) {
    return c.json({ error: 'Invalid index' }, 400);
  }

  keysStore.providers[index].enabled = !keysStore.providers[index].enabled;
  keysStore.version++;
  saveKeysToFile(keysStore);

  return c.json({ success: true, enabled: keysStore.providers[index].enabled });
});

app.get('/admin/api/keys', (c) => {
  // Return providers without exposing full keys
  const safeProviders = keysStore.providers.map(p => ({
    ...p,
    apiKey: p.apiKey ? p.apiKey.substring(0, 8) + '...' : '',
  }));
  return c.json({ providers: safeProviders, version: keysStore.version });
});

// Cost tracking endpoint
app.get('/admin/costs', (c) => {
  const last100 = costLog.slice(-100);
  const totalCost = costLog.reduce((sum, entry) => sum + (entry.estimatedCost || 0), 0);

  return c.json({
    totalRequests: costLog.length,
    totalEstimatedCost: totalCost.toFixed(4),
    recentRequests: last100,
  });
});

// =============================================================================
// ADMIN CONFIG ENDPOINTS
// =============================================================================

app.get('/admin/api/config', (c) => {
  return c.json(adminConfig);
});

app.put('/admin/api/config', async (c) => {
  const body = await c.req.json() as Partial<AdminConfig>;
  adminConfig = { ...adminConfig, ...body };
  saveAdminConfig(adminConfig);
  return c.json({ success: true, config: adminConfig });
});

// =============================================================================
// CONSOLE KEY ENTRY API - Called from chat to add keys
// =============================================================================

// Lookup provider by short name (e.g., "anthropic", "openai")
function findProviderByName(name: string): StoredProvider | undefined {
  const normalizedName = name.toLowerCase().trim();
  return keysStore.providers.find(p =>
    p.name.toLowerCase() === normalizedName ||
    p.host.toLowerCase().includes(normalizedName) ||
    normalizedName.includes(p.name.toLowerCase().split(' ')[0])
  );
}

// POST /v1/keys/:provider - Add a key from console chat
// Example: POST /v1/keys/anthropic { "key": "sk-ant-..." }
// Returns: { "success": true, "provider": "Anthropic", "redacted": "sk-ant-a...xyz1" }
app.post('/v1/keys/:provider', async (c) => {
  const providerName = c.req.param('provider');
  const body = await c.req.json() as { key: string };

  if (!body.key) {
    return c.json({ error: 'Missing key in request body' }, 400);
  }

  // Check if provider is allowed
  if (adminConfig.allowedServices.length > 0) {
    const isAllowed = adminConfig.allowedServices.some(s =>
      s.toLowerCase() === providerName.toLowerCase()
    );
    if (!isAllowed) {
      return c.json({
        error: 'Provider not allowed',
        message: `${providerName} is not in the allowed services list. Contact your admin.`,
        allowedServices: adminConfig.allowedServices,
      }, 403);
    }
  }

  // Find provider template
  const provider = findProviderByName(providerName);
  if (!provider) {
    const availableProviders = keysStore.providers.map(p => p.name.toLowerCase());
    return c.json({
      error: 'Unknown provider',
      message: `Provider "${providerName}" not found.`,
      availableProviders,
    }, 404);
  }

  // Check for admin approval requirement
  if (adminConfig.requireKeyApproval && !provider.apiKey) {
    // Store as pending (disabled) for admin approval
    provider.apiKey = body.key;
    provider.enabled = false;
    provider.addedAt = new Date().toISOString();
    keysStore.version++;
    saveKeysToFile(keysStore);

    const redacted = body.key.substring(0, 8) + '...' + body.key.slice(-4);
    return c.json({
      success: true,
      pending: true,
      provider: provider.name,
      redacted,
      message: 'Key saved but requires admin approval before activation.',
    });
  }

  // Save and enable the key
  provider.apiKey = body.key;
  provider.enabled = true;
  provider.addedAt = new Date().toISOString();
  keysStore.version++;
  saveKeysToFile(keysStore);

  const redacted = body.key.substring(0, 8) + '...' + body.key.slice(-4);
  console.log(`[KEYS] Added key for ${provider.name} via console API (${redacted})`);

  return c.json({
    success: true,
    provider: provider.name,
    host: provider.host,
    redacted,
    message: `${provider.name} API key configured and active.`,
  });
});

// DELETE /v1/keys/:provider - Remove a key
app.delete('/v1/keys/:provider', (c) => {
  const providerName = c.req.param('provider');
  const provider = findProviderByName(providerName);

  if (!provider) {
    return c.json({ error: 'Provider not found' }, 404);
  }

  provider.apiKey = '';
  provider.enabled = false;
  keysStore.version++;
  saveKeysToFile(keysStore);

  console.log(`[KEYS] Removed key for ${provider.name} via console API`);

  return c.json({
    success: true,
    provider: provider.name,
    message: `${provider.name} API key removed.`,
  });
});

// GET /v1/keys - List configured providers (without exposing full keys)
app.get('/v1/keys', (c) => {
  const providers = keysStore.providers.map(p => ({
    name: p.name,
    host: p.host,
    hasKey: !!p.apiKey,
    enabled: p.enabled,
    redacted: p.apiKey ? p.apiKey.substring(0, 8) + '...' + p.apiKey.slice(-4) : null,
  }));

  return c.json({
    providers,
    allowedServices: adminConfig.allowedServices.length > 0 ? adminConfig.allowedServices : 'all',
    requireApproval: adminConfig.requireKeyApproval,
  });
});

// POST /v1/redact - Utility to redact API keys from text
// Used by console to sanitize chat logs before displaying/saving
app.post('/v1/redact', async (c) => {
  const body = await c.req.json() as { text: string };

  if (!body.text) {
    return c.json({ error: 'Missing text in request body' }, 400);
  }

  const { redacted, found } = redactApiKeys(body.text);

  return c.json({
    original_length: body.text.length,
    redacted_length: redacted.length,
    redacted,
    keys_found: found.length,
    found,
  });
});

// 404 handler
app.notFound((c) => {
  return c.json({ error: 'Not found', path: c.req.path }, 404);
});

// Error handler
app.onError((err, c) => {
  console.error('Server error:', err);
  return c.json({ error: 'Internal server error', details: err.message }, 500);
});

// =============================================================================
// MITM PROXY - Intercepts all HTTP/HTTPS traffic, injects API keys
// =============================================================================

const mitmProxy = new Proxy();

// Handle request interception
mitmProxy.onRequest((ctx, callback) => {
  const host = ctx.clientToProxyRequest.headers.host || '';
  const method = ctx.clientToProxyRequest.method;
  const url = ctx.clientToProxyRequest.url;

  console.log(`[MITM] ${method} ${ctx.isSSL ? 'https' : 'http'}://${host}${url}`);

  // Check if this is a known API provider (from dynamic key store)
  const providers = getActiveProviders();
  const provider = providers.get(host);

  if (provider) {
    // Build the auth value with optional prefix (e.g., "Bearer ")
    const authValue = (provider.authPrefix || '') + provider.apiKey;

    // Inject authentication header
    ctx.proxyToServerRequestOptions.headers[provider.authHeader] = authValue;
    console.log(`[MITM] Injected ${provider.authHeader} for ${host}`);

    // Update last used timestamp
    const storeProvider = keysStore.providers.find(p => p.host === host);
    if (storeProvider) {
      storeProvider.lastUsed = new Date().toISOString();
    }

    // Add extra headers if configured
    if (provider.extraHeaders) {
      for (const [key, value] of Object.entries(provider.extraHeaders)) {
        ctx.proxyToServerRequestOptions.headers[key] = value;
      }
    }
  }

  return callback();
});

// Handle response for cost tracking
mitmProxy.onResponse((ctx, callback) => {
  const host = ctx.clientToProxyRequest.headers.host || '';
  const providers = getActiveProviders();
  const provider = providers.get(host);

  if (provider) {
    // Collect response body for cost tracking
    let responseBody = '';
    const originalWrite = ctx.proxyToClientResponse.write.bind(ctx.proxyToClientResponse);
    const originalEnd = ctx.proxyToClientResponse.end.bind(ctx.proxyToClientResponse);

    ctx.proxyToClientResponse.write = function(chunk: any, ...args: any[]) {
      if (chunk) {
        responseBody += chunk.toString();
      }
      return originalWrite(chunk, ...args);
    };

    ctx.proxyToClientResponse.end = function(chunk: any, ...args: any[]) {
      if (chunk) {
        responseBody += chunk.toString();
      }

      // Track cost asynchronously
      try {
        const parsedResponse = JSON.parse(responseBody);
        const providerName = host.includes('anthropic') ? 'anthropic' : 'openai';
        trackCost(providerName, ctx.clientToProxyRequest.url || '', ctx.clientToProxyRequest.method || 'GET', undefined, parsedResponse);
      } catch {
        // Not JSON, skip cost tracking
      }

      return originalEnd(chunk, ...args);
    };
  }

  return callback();
});

// Handle errors
mitmProxy.onError((_ctx, err) => {
  console.error('[MITM] Proxy error:', err);
});

// =============================================================================
// START SERVERS
// =============================================================================

// Build provider list for banner
const startupProviders = getActiveProviders();
const providerList = Array.from(startupProviders.keys());
const providerDisplay = providerList.length > 0
  ? providerList.map(h => `║    • ${h.padEnd(54)}║`).join('\n')
  : '║    (no API keys configured - use Admin UI to add)            ║';

console.log(`
╔════════════════════════════════════════════════════════════════╗
║               Boardroom API Proxy Server                       ║
╠════════════════════════════════════════════════════════════════╣
║  Admin UI:    http://0.0.0.0:${config.port}/admin${' '.repeat(30)}║
║  MITM Proxy:  http://0.0.0.0:${config.proxyPort}${' '.repeat(36)}║
║  Keys File:   ${KEYS_FILE.padEnd(49)}║
╠════════════════════════════════════════════════════════════════╣
║  Active Providers (${providerList.length.toString().padEnd(2)} configured):                         ║
${providerDisplay}
╠════════════════════════════════════════════════════════════════╣
║  Keys can be added/edited via Admin UI - no restart needed!    ║
║  Console config: HTTP_PROXY=http://proxy:${config.proxyPort}                 ║
╚════════════════════════════════════════════════════════════════╝
`);

// Start Hono server (admin + direct endpoints)
serve({
  fetch: app.fetch,
  port: config.port,
});

// Start MITM proxy
mitmProxy.listen({
  port: config.proxyPort,
  sslCaDir: certsDir,
}, () => {
  console.log(`[MITM] Proxy listening on port ${config.proxyPort}`);
  console.log(`[MITM] CA certificates stored in: ${certsDir}`);
});
