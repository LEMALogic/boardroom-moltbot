import { Hono } from 'hono';
import { serve } from '@hono/node-server';
import { logger } from 'hono/logger';
import { cors } from 'hono/cors';
import { timing } from 'hono/timing';
// http-mitm-proxy is a CommonJS module - use createRequire for ESM compatibility
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { Proxy: MitmProxy } = require('http-mitm-proxy');
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { existsSync, mkdirSync, readFileSync, writeFileSync, watchFile } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// =============================================================================
// KEY ALIAS STORE - Dynamic, no hardcoded providers
// =============================================================================
//
// Each alias is a complete key configuration that can be looked up by name.
// Multiple aliases can point to the same provider host (for different budgets/accounts).
// Each host can have a designated default alias.
//
// Example aliases:
//   "lema-openrouter-main" -> { host: "openrouter.ai", key: "sk-or-...", budget: "main" }
//   "lema-openrouter-dev"  -> { host: "openrouter.ai", key: "sk-or-...", budget: "dev" }
//   "lema-anthropic-brian" -> { host: "api.anthropic.com", key: "sk-ant-...", budget: "brian" }
//
// =============================================================================

const DATA_DIR = process.env.DATA_DIR || '/data';
const ALIASES_FILE = join(DATA_DIR, 'key-aliases.json');
const CONFIG_FILE = join(DATA_DIR, 'proxy-config.json');
const MAX_TRACKED_RESPONSE_BYTES = 1_000_000;
const MAX_ALIAS_TEXT_LENGTH = 256;
const MAX_DESCRIPTION_LENGTH = 512;
const MAX_HEADER_VALUE_LENGTH = 512;
const MAX_KEY_LENGTH = 2048;

// A key alias - complete configuration for one API key
interface KeyAlias {
  alias: string;              // Unique identifier (e.g., "lema-openrouter-main")
  description: string;        // Human-readable description
  host: string;               // API host to match (e.g., "openrouter.ai")
  authHeader: string;         // Header name (e.g., "Authorization", "x-api-key")
  authPrefix?: string;        // Optional prefix (e.g., "Bearer ")
  extraHeaders?: Record<string, string>;  // Additional headers to inject
  key: string;                // The actual API key
  budget?: string;            // Budget group for cost tracking
  enabled: boolean;           // Whether this alias is active
  isDefault?: boolean;        // Whether this is the default for its host
  addedAt: string;            // ISO timestamp when added
  lastUsed?: string;          // ISO timestamp of last use
  usageCount?: number;        // Number of times used
}

interface AliasStore {
  aliases: KeyAlias[];
  version: number;
}

// Proxy configuration
interface ProxyConfig {
  // Global settings
  globalDailyCap: number;           // Max USD per day across all aliases (0 = unlimited)
  requireApproval: boolean;         // New aliases require admin approval
  logRequests: boolean;             // Log all proxied requests

  // Per-host defaults (which alias to use when no X-Key-Alias header)
  hostDefaults: Record<string, string>;  // host -> alias name
}

// =============================================================================
// STORE MANAGEMENT
// =============================================================================

let aliasStore: AliasStore = { aliases: [], version: 1 };
let proxyConfig: ProxyConfig = {
  globalDailyCap: 0,
  requireApproval: false,
  logRequests: true,
  hostDefaults: {},
};

function ensureDataDir() {
  if (!existsSync(DATA_DIR)) {
    mkdirSync(DATA_DIR, { recursive: true });
  }
}

function loadAliasStore(): AliasStore {
  ensureDataDir();
  if (existsSync(ALIASES_FILE)) {
    try {
      const data = readFileSync(ALIASES_FILE, 'utf-8');
      const store = JSON.parse(data) as AliasStore;
      console.log(`[ALIASES] Loaded ${store.aliases.filter(a => a.enabled).length} active aliases from ${ALIASES_FILE}`);
      return store;
    } catch (err) {
      console.error(`[ALIASES] Error loading aliases:`, err);
    }
  }
  return { aliases: [], version: 1 };
}

function saveAliasStore(store: AliasStore) {
  ensureDataDir();
  try {
    writeFileSync(ALIASES_FILE, JSON.stringify(store, null, 2));
    console.log(`[ALIASES] Saved ${store.aliases.length} aliases to ${ALIASES_FILE}`);
  } catch (err) {
    console.error(`[ALIASES] Error saving aliases:`, err);
  }
}

function loadProxyConfig(): ProxyConfig {
  ensureDataDir();
  if (existsSync(CONFIG_FILE)) {
    try {
      return JSON.parse(readFileSync(CONFIG_FILE, 'utf-8'));
    } catch (err) {
      console.error('[CONFIG] Error loading config:', err);
    }
  }
  return proxyConfig;
}

function saveProxyConfig(config: ProxyConfig) {
  ensureDataDir();
  writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));
  console.log('[CONFIG] Saved config to', CONFIG_FILE);
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function jsStringLiteral(value: string): string {
  return JSON.stringify(value);
}

function safeJsonForHtml(value: unknown): string {
  return JSON.stringify(value).replace(/</g, '\\u003c');
}

function normalizeString(value: unknown, maxLength: number, field: string): string {
  if (typeof value !== 'string') {
    throw new Error(`Field "${field}" must be a string`);
  }
  const trimmed = value.trim();
  if (!trimmed) {
    throw new Error(`Field "${field}" is required`);
  }
  if (trimmed.length > maxLength) {
    throw new Error(`Field "${field}" exceeds max length ${maxLength}`);
  }
  if (/\p{C}/u.test(trimmed)) {
    throw new Error(`Field "${field}" contains invalid characters`);
  }
  return trimmed;
}

function normalizeOptionalString(value: unknown, maxLength: number, field: string): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'string') {
    throw new Error(`Field "${field}" must be a string`);
  }
  const trimmed = value.trim();
  if (!trimmed) return undefined;
  if (trimmed.length > maxLength) {
    throw new Error(`Field "${field}" exceeds max length ${maxLength}`);
  }
  if (/\p{C}/u.test(trimmed)) {
    throw new Error(`Field "${field}" contains invalid characters`);
  }
  return trimmed;
}

function validateAliasName(value: string): string {
  if (!/^[A-Za-z0-9._-]+$/.test(value)) {
    throw new Error('Alias contains invalid characters');
  }
  return value;
}

function validateHost(value: string): string {
  const host = value.toLowerCase();
  if (/\s|\//.test(host)) {
    throw new Error('Host must be a hostname without spaces or slashes');
  }
  return host;
}

function validateHeaderName(value: string): string {
  if (!/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(value)) {
    throw new Error('Header name is invalid');
  }
  return value;
}

function normalizeAliasPayload(body: Partial<KeyAlias>): {
  alias: string;
  description: string;
  host: string;
  authHeader: string;
  authPrefix?: string;
  extraHeaders?: Record<string, string>;
  key: string;
  budget?: string;
  isDefault: boolean;
} {
  const aliasRaw = normalizeString(body.alias, MAX_ALIAS_TEXT_LENGTH, 'alias');
  const alias = validateAliasName(aliasRaw);
  const host = validateHost(normalizeString(body.host, MAX_ALIAS_TEXT_LENGTH, 'host'));
  const authHeader = validateHeaderName(normalizeString(body.authHeader, MAX_ALIAS_TEXT_LENGTH, 'authHeader'));
  const authPrefix = normalizeOptionalString(body.authPrefix, MAX_HEADER_VALUE_LENGTH, 'authPrefix');
  const key = normalizeString(body.key, MAX_KEY_LENGTH, 'key');
  const description = normalizeOptionalString(body.description, MAX_DESCRIPTION_LENGTH, 'description') || '';
  const budget = normalizeOptionalString(body.budget, MAX_ALIAS_TEXT_LENGTH, 'budget');
  const extraHeaders = normalizeExtraHeaders(body.extraHeaders);
  const isDefault = Boolean(body.isDefault);

  return {
    alias,
    description,
    host,
    authHeader,
    authPrefix,
    extraHeaders,
    key,
    budget,
    isDefault,
  };
}

function normalizeAliasUpdate(body: Partial<KeyAlias>): Partial<KeyAlias> {
  const update: Partial<KeyAlias> = {};

  if (body.description !== undefined) {
    update.description = normalizeOptionalString(body.description, MAX_DESCRIPTION_LENGTH, 'description') || '';
  }
  if (body.host !== undefined) {
    update.host = validateHost(normalizeString(body.host, MAX_ALIAS_TEXT_LENGTH, 'host'));
  }
  if (body.authHeader !== undefined) {
    update.authHeader = validateHeaderName(normalizeString(body.authHeader, MAX_ALIAS_TEXT_LENGTH, 'authHeader'));
  }
  if (body.authPrefix !== undefined) {
    update.authPrefix = normalizeOptionalString(body.authPrefix, MAX_HEADER_VALUE_LENGTH, 'authPrefix');
  }
  if (body.extraHeaders !== undefined) {
    update.extraHeaders = normalizeExtraHeaders(body.extraHeaders);
  }
  if (body.key !== undefined) {
    update.key = normalizeString(body.key, MAX_KEY_LENGTH, 'key');
  }
  if (body.budget !== undefined) {
    update.budget = normalizeOptionalString(body.budget, MAX_ALIAS_TEXT_LENGTH, 'budget');
  }
  if (body.enabled !== undefined) {
    update.enabled = Boolean(body.enabled);
  }
  if (body.isDefault !== undefined) {
    update.isDefault = Boolean(body.isDefault);
  }

  return update;
}

function normalizeExtraHeaders(value: unknown): Record<string, string> | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('extraHeaders must be an object');
  }
  const headers: Record<string, string> = {};
  for (const [key, rawValue] of Object.entries(value as Record<string, unknown>)) {
    if (typeof rawValue !== 'string') {
      throw new Error(`extraHeaders value for "${key}" must be a string`);
    }
    const headerName = validateHeaderName(key);
    const headerValue = normalizeString(rawValue, MAX_HEADER_VALUE_LENGTH, `extraHeaders.${key}`);
    headers[headerName] = headerValue;
  }
  return headers;
}

const HOP_BY_HOP_HEADERS = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'proxy-connection',
]);

function filterRequestHeaders(original: Headers): Headers {
  const headers = new Headers();
  for (const [key, value] of original.entries()) {
    const lower = key.toLowerCase();
    if (HOP_BY_HOP_HEADERS.has(lower)) continue;
    if (lower === 'host' || lower === 'content-length') continue;
    headers.append(key, value);
  }
  return headers;
}

function filterResponseHeaders(original: Headers): Headers {
  const headers = new Headers();
  for (const [key, value] of original.entries()) {
    const lower = key.toLowerCase();
    if (HOP_BY_HOP_HEADERS.has(lower)) continue;
    headers.append(key, value);
  }
  return headers;
}

async function readJsonIfSmall(response: Response, maxBytes: number): Promise<unknown | undefined> {
  const contentType = response.headers.get('content-type') || '';
  if (!contentType.toLowerCase().includes('application/json')) {
    return undefined;
  }

  const body = response.body;
  if (!body) return undefined;

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    total += value.length;
    if (total > maxBytes) {
      return undefined;
    }
    chunks.push(value);
  }

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }

  try {
    const text = new TextDecoder().decode(merged);
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

// Load on startup
aliasStore = loadAliasStore();
proxyConfig = loadProxyConfig();

// Watch for file changes and hot-reload
if (existsSync(ALIASES_FILE)) {
  watchFile(ALIASES_FILE, { interval: 1000 }, () => {
    console.log(`[ALIASES] Detected changes, reloading...`);
    aliasStore = loadAliasStore();
  });
}

if (existsSync(CONFIG_FILE)) {
  watchFile(CONFIG_FILE, { interval: 1000 }, () => {
    console.log(`[CONFIG] Detected changes, reloading...`);
    proxyConfig = loadProxyConfig();
  });
}

// =============================================================================
// ALIAS LOOKUP
// =============================================================================

// Get alias by name
function getAliasByName(name: string): KeyAlias | undefined {
  return aliasStore.aliases.find(a => a.alias === name && a.enabled);
}

// Get default alias for a host
function getDefaultAliasForHost(host: string): KeyAlias | undefined {
  // First check explicit default in config
  const defaultName = proxyConfig.hostDefaults[host];
  if (defaultName) {
    const alias = getAliasByName(defaultName);
    if (alias) return alias;
  }

  // Fall back to first enabled alias for this host marked as default
  const defaultAlias = aliasStore.aliases.find(a => a.host === host && a.enabled && a.isDefault);
  if (defaultAlias) return defaultAlias;

  // Fall back to first enabled alias for this host
  return aliasStore.aliases.find(a => a.host === host && a.enabled);
}

// Get all aliases for a host (exported for potential external use)
export function getAliasesForHost(host: string): KeyAlias[] {
  return aliasStore.aliases.filter(a => a.host === host);
}

// Get all unique hosts
function getUniqueHosts(): string[] {
  return [...new Set(aliasStore.aliases.map(a => a.host))];
}

// =============================================================================
// KEY REDACTION PATTERNS
// =============================================================================

const API_KEY_PATTERNS: { name: string; pattern: RegExp }[] = [
  { name: 'Anthropic', pattern: /sk-ant-api\d{2}-[A-Za-z0-9_-]{86,}/g },
  { name: 'OpenAI', pattern: /sk-[A-Za-z0-9]{20,}/g },
  { name: 'OpenRouter', pattern: /sk-or-v1-[A-Za-z0-9]{64}/g },
  { name: 'ElevenLabs', pattern: /xi-[A-Za-z0-9]{32}/g },
  { name: 'Google AI', pattern: /AIza[A-Za-z0-9_-]{35}/g },
  { name: 'Replicate', pattern: /r8_[A-Za-z0-9]{37}/g },
  { name: 'Hugging Face', pattern: /hf_[A-Za-z0-9]{34}/g },
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

// =============================================================================
// COST TRACKING
// =============================================================================

interface CostEntry {
  timestamp: string;
  alias: string;
  host: string;
  path: string;
  method: string;
  inputTokens?: number;
  outputTokens?: number;
  model?: string;
  estimatedCost?: number;
  budget?: string;
}

const costLog: CostEntry[] = [];

function estimateCost(_host: string, model: string | undefined, inputTokens: number, outputTokens: number): number {
  // Dynamic rate lookup - could be extended to store rates per alias
  const rates: Record<string, { input: number; output: number }> = {
    'claude-opus-4': { input: 15, output: 75 },
    'claude-sonnet-4': { input: 3, output: 15 },
    'claude-3-opus': { input: 15, output: 75 },
    'claude-3-sonnet': { input: 3, output: 15 },
    'claude-3-haiku': { input: 0.25, output: 1.25 },
    'gpt-4-turbo': { input: 10, output: 30 },
    'gpt-4o': { input: 5, output: 15 },
    'gpt-4': { input: 30, output: 60 },
    'gpt-3.5': { input: 0.5, output: 1.5 },
  };

  const defaultRate = { input: 5, output: 15 };
  let rate = defaultRate;

  if (model) {
    for (const [key, value] of Object.entries(rates)) {
      if (model.toLowerCase().includes(key.toLowerCase())) {
        rate = value;
        break;
      }
    }
  }

  return (inputTokens * rate.input + outputTokens * rate.output) / 1_000_000;
}

function trackCost(alias: KeyAlias, path: string, method: string, responseBody: unknown) {
  const entry: CostEntry = {
    timestamp: new Date().toISOString(),
    alias: alias.alias,
    host: alias.host,
    path,
    method,
    budget: alias.budget,
  };

  if (responseBody && typeof responseBody === 'object') {
    const resp = responseBody as Record<string, unknown>;

    if (resp.usage && typeof resp.usage === 'object') {
      const usage = resp.usage as Record<string, number>;
      entry.inputTokens = usage.input_tokens || usage.prompt_tokens;
      entry.outputTokens = usage.output_tokens || usage.completion_tokens;
    }

    if (resp.model) {
      entry.model = resp.model as string;
    }
  }

  if (entry.inputTokens && entry.outputTokens) {
    entry.estimatedCost = estimateCost(alias.host, entry.model, entry.inputTokens, entry.outputTokens);
  }

  costLog.push(entry);

  // Keep last 10000 entries
  if (costLog.length > 10000) {
    costLog.splice(0, costLog.length - 10000);
  }
}

// =============================================================================
// CONFIGURATION
// =============================================================================

const serverConfig = {
  port: parseInt(process.env.PORT || '8080', 10),
  proxyPort: parseInt(process.env.PROXY_PORT || '3128', 10),
};

// Ensure certs directory exists
const certsDir = join(__dirname, '..', 'certs', '.http-mitm-proxy');
if (!existsSync(certsDir)) {
  mkdirSync(certsDir, { recursive: true });
}

// =============================================================================
// HONO APP - Admin UI and API
// =============================================================================

const app = new Hono();

app.use('*', cors());
app.use('*', timing());
app.use('*', logger());

// Health check
app.get('/health', (c) => {
  const activeAliases = aliasStore.aliases.filter(a => a.enabled);
  const hosts = getUniqueHosts();

  return c.json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    activeAliases: activeAliases.length,
    totalAliases: aliasStore.aliases.length,
    hosts: hosts.length,
  });
});

// Admin UI
app.get('/admin', (c) => {
  const aliases = aliasStore.aliases;
  const activeCount = aliases.filter(a => a.enabled).length;
  const hosts = getUniqueHosts();
  const totalCost = costLog.reduce((sum, e) => sum + (e.estimatedCost || 0), 0);

  // Group aliases by host for display
  const aliasesByHost: Record<string, KeyAlias[]> = {};
  for (const alias of aliases) {
    if (!aliasesByHost[alias.host]) {
      aliasesByHost[alias.host] = [];
    }
    aliasesByHost[alias.host].push(alias);
  }

  return c.html(`
    <!DOCTYPE html>
    <html>
    <head>
      <title>Boardroom API Proxy - Admin</title>
      <style>
        * { box-sizing: border-box; }
        body { font-family: system-ui, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px; background: #0a0a0a; color: #e0e0e0; }
        h1 { color: #fff; margin-bottom: 5px; }
        .subtitle { color: #888; margin-bottom: 30px; }
        .card { background: #1a1a1a; padding: 20px; border-radius: 8px; margin: 20px 0; border: 1px solid #333; }
        .card h2 { margin-top: 0; color: #fff; display: flex; align-items: center; gap: 10px; }
        .badge { background: #333; padding: 4px 10px; border-radius: 12px; font-size: 12px; font-weight: normal; }
        .badge.active { background: #1a3d1a; color: #4ade80; }
        .badge.default { background: #1a3d3d; color: #4adede; }
        table { width: 100%; border-collapse: collapse; }
        th { text-align: left; padding: 12px; border-bottom: 2px solid #333; color: #888; font-weight: 500; }
        td { padding: 12px; border-bottom: 1px solid #222; }
        .status { display: inline-block; padding: 4px 12px; border-radius: 4px; font-weight: 500; font-size: 12px; }
        .status.active { background: #1a3d1a; color: #4ade80; }
        .status.inactive { background: #3d1a1a; color: #fa5c5c; }
        code { background: #333; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
        input[type="text"], input[type="password"], select {
          background: #222; border: 1px solid #444; color: #fff; padding: 8px 12px;
          border-radius: 4px; width: 100%; font-family: monospace;
        }
        input:focus, select:focus { outline: none; border-color: #667eea; }
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
        .stats { display: flex; gap: 20px; margin-bottom: 20px; flex-wrap: wrap; }
        .stat { background: #16213e; padding: 15px 25px; border-radius: 8px; text-align: center; min-width: 120px; }
        .stat .number { font-size: 28px; font-weight: bold; color: #667eea; }
        .stat .label { font-size: 12px; color: #888; margin-top: 5px; }
        a { color: #60a5fa; }
        .masked { font-family: monospace; color: #888; }
        .host-section { margin-top: 30px; }
        .host-header { background: #252525; padding: 10px 15px; border-radius: 8px 8px 0 0; border: 1px solid #333; border-bottom: none; }
        .host-header h3 { margin: 0; color: #fff; font-size: 16px; }
        .host-table { border: 1px solid #333; border-radius: 0 0 8px 8px; overflow: hidden; }
        .form-row { display: flex; gap: 10px; margin-bottom: 10px; }
        .form-row > * { flex: 1; }
        .form-row label { display: block; font-size: 12px; color: #888; margin-bottom: 4px; }
        .warning { background: #3d2a1a; border: 1px solid #f59e0b; padding: 15px; border-radius: 8px; margin-bottom: 20px; }
        .warning h3 { color: #f59e0b; margin: 0 0 10px 0; font-size: 14px; }
        .warning p { margin: 0; font-size: 13px; color: #d4a574; }
      </style>
    </head>
    <body>
      <h1>🔑 Boardroom API Proxy</h1>
      <p class="subtitle">Key Alias Management Console</p>

      <div class="warning">
        <h3>⚠️ Compliance Notice</h3>
        <p>Adding new AI services may require security assessment, GDPR compliance review,
        Data Processing Agreement (DPA), or Data Protection Impact Assessment (DPIA).
        Contact your IT/Security team before adding new providers.</p>
      </div>

      <div class="stats">
      <div class="stat">
        <div class="number">${activeCount}</div>
        <div class="label">Active Aliases</div>
      </div>
        <div class="stat">
          <div class="number">${hosts.length}</div>
          <div class="label">Unique Hosts</div>
        </div>
        <div class="stat">
          <div class="number">${costLog.length}</div>
          <div class="label">Requests Logged</div>
        </div>
        <div class="stat">
          <div class="number">$${totalCost.toFixed(2)}</div>
          <div class="label">Est. Total Cost</div>
        </div>
      </div>

      <div class="card">
        <h2>Add New Alias</h2>
        <form id="add-alias-form">
          <div class="form-row">
            <div>
              <label>Alias Name</label>
              <input type="text" name="alias" placeholder="e.g., lema-openrouter-main" required>
            </div>
            <div>
              <label>Description</label>
              <input type="text" name="description" placeholder="e.g., Main OpenRouter account for LEMA">
            </div>
          </div>
          <div class="form-row">
            <div>
              <label>API Host</label>
              <input type="text" name="host" placeholder="e.g., openrouter.ai, api.anthropic.com" required>
            </div>
            <div>
              <label>Auth Header</label>
              <input type="text" name="authHeader" placeholder="e.g., Authorization, x-api-key" required>
            </div>
          </div>
          <div class="form-row">
            <div>
              <label>Auth Prefix (optional)</label>
              <input type="text" name="authPrefix" placeholder="e.g., Bearer ">
            </div>
            <div>
              <label>Budget Group (optional)</label>
              <input type="text" name="budget" placeholder="e.g., main, dev, brian-personal">
            </div>
          </div>
          <div class="form-row">
            <div>
              <label>API Key</label>
              <input type="password" name="key" placeholder="sk-..." required>
            </div>
            <div>
              <label>Extra Headers (JSON, optional)</label>
              <input type="text" name="extraHeaders" placeholder='{"anthropic-version": "2023-06-01"}'>
            </div>
          </div>
          <div class="form-row">
            <div style="flex: none;">
              <label>&nbsp;</label>
              <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
                <input type="checkbox" name="isDefault" style="width: 18px; height: 18px;">
                <span>Set as default for this host</span>
              </label>
            </div>
            <div style="flex: none; margin-left: auto;">
              <label>&nbsp;</label>
              <button type="submit">Add Alias</button>
            </div>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>Key Aliases <span class="badge active">${activeCount} active</span></h2>

        ${hosts.length === 0 ? `
          <p style="color: #888; text-align: center; padding: 40px;">
            No aliases configured yet. Add your first alias above.
          </p>
        ` : hosts.map(host => `
          <div class="host-section">
            <div class="host-header">
              <h3><code>${escapeHtml(host)}</code> ${proxyConfig.hostDefaults[host] ? `<span class="badge default">default: ${escapeHtml(proxyConfig.hostDefaults[host])}</span>` : ''}</h3>
            </div>
            <table class="host-table">
              <thead>
                <tr>
                  <th>Alias</th>
                  <th>Description</th>
                  <th>Budget</th>
                  <th>Key</th>
                  <th>Status</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                ${aliasesByHost[host].map(a => `
                  <tr data-alias="${escapeHtml(a.alias)}">
                    <td>
                      <strong>${escapeHtml(a.alias)}</strong>
                      ${a.isDefault ? '<span class="badge default" style="margin-left:8px;">default</span>' : ''}
                    </td>
                    <td style="color:#888;">${a.description ? escapeHtml(a.description) : '-'}</td>
                    <td><code>${a.budget ? escapeHtml(a.budget) : 'none'}</code></td>
                    <td><span class="masked">${a.key ? escapeHtml(a.key.substring(0, 8) + '...' + a.key.slice(-4)) : '(not set)'}</span></td>
                    <td>
                      <span class="status ${a.enabled ? 'active' : 'inactive'}">
                        ${a.enabled ? '✓ Active' : '✗ Disabled'}
                      </span>
                    </td>
                    <td class="actions">
                      <button class="secondary" onclick="editAlias(${jsStringLiteral(a.alias)})">Edit</button>
                      <button class="secondary" onclick="toggleAlias(${jsStringLiteral(a.alias)})">${a.enabled ? 'Disable' : 'Enable'}</button>
                      <button class="secondary" onclick="setDefault(${jsStringLiteral(a.alias)}, ${jsStringLiteral(host)})">Set Default</button>
                      <button class="danger" onclick="deleteAlias(${jsStringLiteral(a.alias)})">Delete</button>
                    </td>
                  </tr>
                `).join('')}
              </tbody>
            </table>
          </div>
        `).join('')}
      </div>

      <div class="card">
        <h2>Proxy Configuration</h2>
        <table>
          <tr><td>Admin Port</td><td><code>${serverConfig.port}</code></td></tr>
          <tr><td>MITM Proxy Port</td><td><code>${serverConfig.proxyPort}</code></td></tr>
          <tr><td>Aliases File</td><td><code>${ALIASES_FILE}</code></td></tr>
          <tr><td>Console Env</td><td><code>HTTPS_PROXY=http://proxy:${serverConfig.proxyPort}</code></td></tr>
          <tr><td>Alias Header</td><td><code>X-Key-Alias: &lt;alias-name&gt;</code></td></tr>
        </table>
      </div>

      <div class="card">
        <h2>Cost Tracking by Budget</h2>
        <p><a href="/admin/costs">View detailed cost data (JSON)</a></p>
        <p><a href="/admin/costs/by-budget">View costs grouped by budget (JSON)</a></p>
      </div>

      <div class="card">
        <h2>OpenRouter Usage</h2>
        <p><a href="/admin/openrouter/usage">View current OpenRouter usage (JSON)</a></p>
        <p><a href="/admin/openrouter/usage/all">View all OpenRouter aliases usage (JSON)</a></p>
      </div>

      <div class="card">
        <h2>API Reference</h2>
        <table>
          <tr><td><code>GET /v1/aliases</code></td><td>List all aliases (keys redacted)</td></tr>
          <tr><td><code>POST /v1/aliases</code></td><td>Add new alias</td></tr>
          <tr><td><code>PUT /v1/aliases/:alias</code></td><td>Update alias</td></tr>
          <tr><td><code>DELETE /v1/aliases/:alias</code></td><td>Delete alias</td></tr>
          <tr><td><code>POST /v1/aliases/:alias/toggle</code></td><td>Enable/disable alias</td></tr>
          <tr><td><code>POST /v1/redact</code></td><td>Redact API keys from text</td></tr>
        </table>
      </div>

      <script>
        const aliases = ${safeJsonForHtml(aliases.map(a => ({ ...a, key: a.key ? a.key.substring(0, 8) + '...' : '' })))};

        document.getElementById('add-alias-form').addEventListener('submit', async (e) => {
          e.preventDefault();
          const form = e.target;
          const data = {
            alias: form.alias.value,
            description: form.description.value,
            host: form.host.value,
            authHeader: form.authHeader.value,
            authPrefix: form.authPrefix.value || undefined,
            extraHeaders: form.extraHeaders.value ? JSON.parse(form.extraHeaders.value) : undefined,
            key: form.key.value,
            budget: form.budget.value || undefined,
            isDefault: form.isDefault.checked,
          };

          const res = await fetch('/v1/aliases', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
          });

          if (res.ok) {
            location.reload();
          } else {
            const err = await res.json();
            alert('Error: ' + (err.error || 'Failed to add alias'));
          }
        });

        async function toggleAlias(alias) {
          const res = await fetch('/v1/aliases/' + encodeURIComponent(alias) + '/toggle', { method: 'POST' });
          if (res.ok) location.reload();
        }

        async function deleteAlias(alias) {
          if (!confirm('Delete alias "' + alias + '"?')) return;
          const res = await fetch('/v1/aliases/' + encodeURIComponent(alias), { method: 'DELETE' });
          if (res.ok) location.reload();
        }

        async function setDefault(alias, host) {
          const res = await fetch('/admin/api/default', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ host, alias })
          });
          if (res.ok) location.reload();
        }

        function editAlias(alias) {
          // For now, just alert - could open modal
          alert('Edit functionality: Delete and re-add with new values, or use the API directly.');
        }
      </script>
    </body>
    </html>
  `);
});

// =============================================================================
// API ENDPOINTS
// =============================================================================

// List all aliases (keys redacted)
app.get('/v1/aliases', (c) => {
  const aliases = aliasStore.aliases.map(a => ({
    ...a,
    key: a.key ? a.key.substring(0, 8) + '...' + a.key.slice(-4) : null,
  }));

  return c.json({
    aliases,
    hostDefaults: proxyConfig.hostDefaults,
    version: aliasStore.version,
  });
});

// Add new alias
app.post('/v1/aliases', async (c) => {
  let body: Partial<KeyAlias>;
  try {
    body = await c.req.json() as Partial<KeyAlias>;
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  let normalized;
  try {
    normalized = normalizeAliasPayload(body);
  } catch (err) {
    return c.json({ error: err instanceof Error ? err.message : 'Invalid alias payload' }, 400);
  }

  // Check for duplicate alias name
  if (aliasStore.aliases.some(a => a.alias === normalized.alias)) {
    return c.json({ error: `Alias "${normalized.alias}" already exists` }, 409);
  }

  const newAlias: KeyAlias = {
    alias: normalized.alias,
    description: normalized.description,
    host: normalized.host,
    authHeader: normalized.authHeader,
    authPrefix: normalized.authPrefix,
    extraHeaders: normalized.extraHeaders,
    key: normalized.key,
    budget: normalized.budget,
    enabled: proxyConfig.requireApproval ? false : true,
    isDefault: normalized.isDefault,
    addedAt: new Date().toISOString(),
    usageCount: 0,
  };

  aliasStore.aliases.push(newAlias);
  aliasStore.version++;
  saveAliasStore(aliasStore);

  // If marked as default, update host defaults
  if (newAlias.isDefault) {
    for (const alias of aliasStore.aliases) {
      if (alias.host === newAlias.host && alias.alias !== newAlias.alias) {
        alias.isDefault = false;
      }
    }
    proxyConfig.hostDefaults[newAlias.host] = newAlias.alias;
    saveProxyConfig(proxyConfig);
  }

  console.log(`[ALIASES] Added new alias: ${newAlias.alias} for ${newAlias.host}`);

  return c.json({
    success: true,
    alias: newAlias.alias,
    host: newAlias.host,
    enabled: newAlias.enabled,
    message: newAlias.enabled
      ? `Alias "${newAlias.alias}" created and active.`
      : `Alias "${newAlias.alias}" created but requires admin approval.`,
  });
});

// Update alias
app.put('/v1/aliases/:alias', async (c) => {
  const aliasName = c.req.param('alias');
  let body: Partial<KeyAlias>;
  try {
    body = await c.req.json() as Partial<KeyAlias>;
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const index = aliasStore.aliases.findIndex(a => a.alias === aliasName);
  if (index === -1) {
    return c.json({ error: `Alias "${aliasName}" not found` }, 404);
  }

  let updates: Partial<KeyAlias>;
  try {
    updates = normalizeAliasUpdate(body);
  } catch (err) {
    return c.json({ error: err instanceof Error ? err.message : 'Invalid alias update' }, 400);
  }

  const previousHost = aliasStore.aliases[index].host;

  // Update fields
  const alias = aliasStore.aliases[index];
  if (updates.description !== undefined) alias.description = updates.description;
  if (updates.host !== undefined) alias.host = updates.host;
  if (updates.authHeader !== undefined) alias.authHeader = updates.authHeader;
  if (updates.authPrefix !== undefined) alias.authPrefix = updates.authPrefix;
  if (updates.extraHeaders !== undefined) alias.extraHeaders = updates.extraHeaders;
  if (updates.key !== undefined) alias.key = updates.key;
  if (updates.budget !== undefined) alias.budget = updates.budget;
  if (updates.enabled !== undefined) alias.enabled = updates.enabled;

  if (updates.isDefault !== undefined) {
    alias.isDefault = updates.isDefault;
  }

  if (previousHost !== alias.host && proxyConfig.hostDefaults[previousHost] === alias.alias) {
    delete proxyConfig.hostDefaults[previousHost];
  }

  if (alias.isDefault) {
    for (const other of aliasStore.aliases) {
      if (other.host === alias.host && other.alias !== alias.alias) {
        other.isDefault = false;
      }
    }
    proxyConfig.hostDefaults[alias.host] = alias.alias;
  } else if (proxyConfig.hostDefaults[alias.host] === alias.alias) {
    delete proxyConfig.hostDefaults[alias.host];
  }

  saveProxyConfig(proxyConfig);

  aliasStore.version++;
  saveAliasStore(aliasStore);

  return c.json({ success: true, alias: aliasName });
});

// Delete alias
app.delete('/v1/aliases/:alias', (c) => {
  const aliasName = c.req.param('alias');

  const index = aliasStore.aliases.findIndex(a => a.alias === aliasName);
  if (index === -1) {
    return c.json({ error: `Alias "${aliasName}" not found` }, 404);
  }

  const removed = aliasStore.aliases.splice(index, 1)[0];
  aliasStore.version++;
  saveAliasStore(aliasStore);

  // Remove from host defaults if it was default
  if (proxyConfig.hostDefaults[removed.host] === removed.alias) {
    delete proxyConfig.hostDefaults[removed.host];
    saveProxyConfig(proxyConfig);
  }

  console.log(`[ALIASES] Deleted alias: ${aliasName}`);

  return c.json({ success: true, alias: aliasName });
});

// Toggle alias enabled/disabled
app.post('/v1/aliases/:alias/toggle', (c) => {
  const aliasName = c.req.param('alias');

  const alias = aliasStore.aliases.find(a => a.alias === aliasName);
  if (!alias) {
    return c.json({ error: `Alias "${aliasName}" not found` }, 404);
  }

  alias.enabled = !alias.enabled;
  aliasStore.version++;
  saveAliasStore(aliasStore);

  return c.json({ success: true, alias: aliasName, enabled: alias.enabled });
});

// Set default alias for a host
app.post('/admin/api/default', async (c) => {
  let body: { host: string; alias: string };
  try {
    body = await c.req.json() as { host: string; alias: string };
  } catch {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  let host: string;
  let aliasName: string;
  try {
    host = validateHost(normalizeString(body.host, MAX_ALIAS_TEXT_LENGTH, 'host'));
    aliasName = validateAliasName(normalizeString(body.alias, MAX_ALIAS_TEXT_LENGTH, 'alias'));
  } catch (err) {
    return c.json({ error: err instanceof Error ? err.message : 'Invalid host or alias' }, 400);
  }

  // Verify alias exists and matches host
  const alias = aliasStore.aliases.find(a => a.alias === aliasName);
  if (!alias) {
    return c.json({ error: `Alias "${aliasName}" not found` }, 404);
  }
  if (alias.host !== host) {
    return c.json({ error: `Alias "${aliasName}" is for host "${alias.host}", not "${host}"` }, 400);
  }

  // Clear isDefault on other aliases for this host
  for (const a of aliasStore.aliases) {
    if (a.host === host) {
      a.isDefault = a.alias === aliasName;
    }
  }

  proxyConfig.hostDefaults[host] = aliasName;
  saveProxyConfig(proxyConfig);
  saveAliasStore(aliasStore);

  return c.json({ success: true, host, defaultAlias: aliasName });
});

// Cost tracking endpoints
app.get('/admin/costs', (c) => {
  const last100 = costLog.slice(-100);
  const totalCost = costLog.reduce((sum, e) => sum + (e.estimatedCost || 0), 0);

  return c.json({
    totalRequests: costLog.length,
    totalEstimatedCost: totalCost.toFixed(4),
    recentRequests: last100,
  });
});

app.get('/admin/costs/by-budget', (c) => {
  const byBudget: Record<string, { requests: number; cost: number }> = {};

  for (const entry of costLog) {
    const budget = entry.budget || 'unassigned';
    if (!byBudget[budget]) {
      byBudget[budget] = { requests: 0, cost: 0 };
    }
    byBudget[budget].requests++;
    byBudget[budget].cost += entry.estimatedCost || 0;
  }

  return c.json({ byBudget });
});

// Redact API keys from text
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

// =============================================================================
// OPENROUTER USAGE ENDPOINT
// =============================================================================
// Fetches usage data from OpenRouter for a specific key

app.get('/admin/openrouter/usage', async (c) => {
  const aliasName = c.req.query('alias');

  // Find OpenRouter aliases
  const openrouterAliases = aliasStore.aliases.filter(a =>
    a.host === 'openrouter.ai' && a.enabled
  );

  if (openrouterAliases.length === 0) {
    return c.json({ error: 'No OpenRouter aliases configured' }, 404);
  }

  // If alias specified, find it; otherwise use default or first
  let alias: KeyAlias | undefined;
  if (aliasName) {
    alias = openrouterAliases.find(a => a.alias === aliasName);
    if (!alias) {
      return c.json({ error: `Alias "${aliasName}" not found` }, 404);
    }
  } else {
    alias = getDefaultAliasForHost('openrouter.ai') || openrouterAliases[0];
  }

  try {
    // Call OpenRouter's /api/v1/auth/key endpoint to get key info
    const response = await fetch('https://openrouter.ai/api/v1/auth/key', {
      headers: {
        'Authorization': `Bearer ${alias.key}`,
      },
    });

    if (!response.ok) {
      const errorText = await response.text();
      return c.json({
        error: 'Failed to fetch usage from OpenRouter',
        status: response.status,
        details: errorText,
      }, response.status as any);
    }

    const data = await response.json() as {
      data?: {
        label?: string;
        usage?: number;
        limit?: number | null;
        limit_remaining?: number | null;
        is_free_tier?: boolean;
        rate_limit?: {
          requests?: number;
          interval?: string;
        };
      };
    };

    // Return usage data with alias info
    return c.json({
      alias: alias.alias,
      budget: alias.budget,
      usage: {
        totalSpend: data.data?.usage || 0,
        limit: data.data?.limit || null,
        limitRemaining: data.data?.limit_remaining || null,
        isFreeTier: data.data?.is_free_tier || false,
        rateLimit: data.data?.rate_limit || null,
      },
      local: {
        usageCount: alias.usageCount || 0,
        lastUsed: alias.lastUsed || null,
      },
    });
  } catch (err) {
    console.error('[OPENROUTER] Error fetching usage:', err);
    return c.json({
      error: 'Failed to fetch usage from OpenRouter',
      details: err instanceof Error ? err.message : String(err),
    }, 500);
  }
});

// Get usage for all OpenRouter aliases
app.get('/admin/openrouter/usage/all', async (c) => {
  const openrouterAliases = aliasStore.aliases.filter(a =>
    a.host === 'openrouter.ai' && a.enabled
  );

  if (openrouterAliases.length === 0) {
    return c.json({ aliases: [], totalSpend: 0 });
  }

  const results = await Promise.all(openrouterAliases.map(async (alias) => {
    try {
      const response = await fetch('https://openrouter.ai/api/v1/auth/key', {
        headers: { 'Authorization': `Bearer ${alias.key}` },
      });

      if (!response.ok) {
        return {
          alias: alias.alias,
          budget: alias.budget,
          error: `HTTP ${response.status}`,
        };
      }

      const data = await response.json() as {
        data?: {
          usage?: number;
          limit?: number | null;
          limit_remaining?: number | null;
        };
      };

      return {
        alias: alias.alias,
        budget: alias.budget,
        usage: data.data?.usage || 0,
        limit: data.data?.limit || null,
        limitRemaining: data.data?.limit_remaining || null,
        usageCount: alias.usageCount || 0,
        lastUsed: alias.lastUsed || null,
      };
    } catch (err) {
      return {
        alias: alias.alias,
        budget: alias.budget,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }));

  const totalSpend = results.reduce((sum, r) => {
    if ('usage' in r && typeof r.usage === 'number') {
      return sum + r.usage;
    }
    return sum;
  }, 0);

  return c.json({
    aliases: results,
    totalSpend,
    timestamp: new Date().toISOString(),
  });
});

// =============================================================================
// FORWARD PROXY ROUTES - Direct API forwarding with key injection
// =============================================================================
// These routes allow clients to call /proxy/{provider}/* and have requests
// forwarded to the real API with the appropriate key injected.
// This is simpler than MITM proxy for containerized deployments.

// Helper to forward requests with key injection
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function forwardWithKey(
  c: any,
  targetHost: string,
  targetPath: string,
  aliasName?: string
) {
  // Find alias for this host
  const alias = aliasName
    ? getAliasByName(aliasName)
    : getDefaultAliasForHost(targetHost);

  if (!alias) {
    return c.json({
      error: `No API key configured for ${targetHost}`,
      hint: 'Add an alias in the admin panel at /admin'
    }, 503);
  }

  // Build target URL
  const targetUrl = `https://${targetHost}${targetPath}`;

  // Build headers - copy from original request, add auth
  const headers = filterRequestHeaders(c.req.raw.headers);

  // Add the API key
  const authValue = (alias.authPrefix || '') + alias.key;
  headers.set(alias.authHeader, authValue);

  // Add extra headers if configured
  if (alias.extraHeaders) {
    for (const [key, value] of Object.entries(alias.extraHeaders)) {
      headers.set(key, value);
    }
  }

  // Log the request
  console.log(`[FORWARD] ${c.req.method} ${targetUrl} via alias "${alias.alias}"`);

  // Update usage stats
  alias.lastUsed = new Date().toISOString();
  alias.usageCount = (alias.usageCount || 0) + 1;

  try {
    const isBodyless = ['GET', 'HEAD'].includes(c.req.method);
    const init: RequestInit & { duplex?: 'half' } = {
      method: c.req.method,
      headers,
      body: isBodyless ? undefined : c.req.raw.body,
    };
    if (!isBodyless) {
      init.duplex = 'half';
    }

    // Forward the request
    const response = await fetch(targetUrl, init);

    // Log cost tracking without blocking the response stream
    void (async () => {
      const usagePayload = await readJsonIfSmall(response.clone(), MAX_TRACKED_RESPONSE_BYTES);
      if (usagePayload) {
        trackCost(alias, targetPath, c.req.method, usagePayload);
      }
    })();

    // Return the streamed response with preserved headers
    return new Response(response.body, {
      status: response.status,
      headers: filterResponseHeaders(response.headers),
    });
  } catch (err) {
    console.error(`[FORWARD] Error forwarding to ${targetUrl}:`, err);
    return c.json({
      error: 'Failed to forward request',
      details: err instanceof Error ? err.message : String(err)
    }, 502);
  }
}

// OpenRouter forward proxy
app.all('/proxy/openrouter/*', async (c) => {
  const path = c.req.path.replace('/proxy/openrouter', '/api/v1');
  return forwardWithKey(c, 'openrouter.ai', path);
});

// Also support /v1/openrouter/* for backwards compatibility with moltbot config
app.all('/v1/openrouter/*', async (c) => {
  const path = c.req.path.replace('/v1/openrouter', '/api/v1');
  return forwardWithKey(c, 'openrouter.ai', path);
});

// Anthropic forward proxy
app.all('/proxy/anthropic/*', async (c) => {
  const path = c.req.path.replace('/proxy/anthropic', '');
  return forwardWithKey(c, 'api.anthropic.com', path);
});

app.all('/v1/anthropic/*', async (c) => {
  const path = c.req.path.replace('/v1/anthropic', '');
  return forwardWithKey(c, 'api.anthropic.com', path);
});

// OpenAI forward proxy
app.all('/proxy/openai/*', async (c) => {
  const path = c.req.path.replace('/proxy/openai', '');
  return forwardWithKey(c, 'api.openai.com', path);
});

app.all('/v1/openai/*', async (c) => {
  const path = c.req.path.replace('/v1/openai', '');
  return forwardWithKey(c, 'api.openai.com', path);
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
// MITM PROXY - Intercepts HTTPS traffic, injects API keys based on alias
// =============================================================================

const mitmProxy = new MitmProxy();

// Handle request interception
// eslint-disable-next-line @typescript-eslint/no-explicit-any
mitmProxy.onRequest((ctx: any, callback: () => void) => {
  const host = ctx.clientToProxyRequest.headers.host || '';
  const method = ctx.clientToProxyRequest.method;
  const url = ctx.clientToProxyRequest.url;

  if (proxyConfig.logRequests) {
    console.log(`[MITM] ${method} ${ctx.isSSL ? 'https' : 'http'}://${host}${url}`);
  }

  // Check for explicit alias header
  const aliasHeader = ctx.clientToProxyRequest.headers['x-key-alias'] as string | undefined;

  let alias: KeyAlias | undefined;

  if (aliasHeader) {
    // Use specified alias
    alias = getAliasByName(aliasHeader);
    if (!alias) {
      console.warn(`[MITM] Requested alias "${aliasHeader}" not found, trying default for ${host}`);
      alias = getDefaultAliasForHost(host);
    }
  } else {
    // Use default alias for this host
    alias = getDefaultAliasForHost(host);
  }

  if (alias) {
    // Build the auth value with optional prefix
    const authValue = (alias.authPrefix || '') + alias.key;

    // Inject authentication header
    ctx.proxyToServerRequestOptions.headers[alias.authHeader] = authValue;

    if (proxyConfig.logRequests) {
      console.log(`[MITM] Using alias "${alias.alias}" for ${host}`);
    }

    // Update usage stats
    alias.lastUsed = new Date().toISOString();
    alias.usageCount = (alias.usageCount || 0) + 1;

    // Add extra headers if configured
    if (alias.extraHeaders) {
      for (const [key, value] of Object.entries(alias.extraHeaders)) {
        ctx.proxyToServerRequestOptions.headers[key] = value;
      }
    }

    // Remove the alias header before forwarding
    delete ctx.proxyToServerRequestOptions.headers['x-key-alias'];
  } else {
    if (proxyConfig.logRequests) {
      console.log(`[MITM] No alias configured for ${host}, passing through`);
    }
  }

  return callback();
});

// Handle response for cost tracking
// eslint-disable-next-line @typescript-eslint/no-explicit-any
mitmProxy.onResponse((ctx: any, callback: () => void) => {
  const host = ctx.clientToProxyRequest.headers.host || '';
  const aliasHeader = ctx.clientToProxyRequest.headers['x-key-alias'] as string | undefined;

  let alias = aliasHeader ? getAliasByName(aliasHeader) : getDefaultAliasForHost(host);

  if (alias) {
    // Collect response body for cost tracking, with size guard
    let responseBody = '';
    let responseBytes = 0;
    let trackingDisabled = false;
    const contentType = String(ctx.proxyToClientResponse.getHeader('content-type') || '');
    const originalWrite = ctx.proxyToClientResponse.write.bind(ctx.proxyToClientResponse);
    const originalEnd = ctx.proxyToClientResponse.end.bind(ctx.proxyToClientResponse);

    ctx.proxyToClientResponse.write = function(chunk: any, ...args: any[]) {
      if (chunk && !trackingDisabled) {
        const chunkBytes = Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(String(chunk));
        responseBytes += chunkBytes;
        if (responseBytes <= MAX_TRACKED_RESPONSE_BYTES) {
          responseBody += chunk.toString();
        } else {
          trackingDisabled = true;
          responseBody = '';
        }
      }
      return originalWrite(chunk, ...args);
    };

    ctx.proxyToClientResponse.end = function(chunk: any, ...args: any[]) {
      if (chunk && !trackingDisabled) {
        const chunkBytes = Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(String(chunk));
        responseBytes += chunkBytes;
        if (responseBytes <= MAX_TRACKED_RESPONSE_BYTES) {
          responseBody += chunk.toString();
        } else {
          trackingDisabled = true;
          responseBody = '';
        }
      }

      // Track cost asynchronously
      if (!trackingDisabled && contentType.toLowerCase().includes('application/json')) {
        try {
          const parsedResponse = JSON.parse(responseBody);
          trackCost(alias!, ctx.clientToProxyRequest.url || '', ctx.clientToProxyRequest.method || 'GET', parsedResponse);
        } catch {
          // Not JSON, skip cost tracking
        }
      }

      return originalEnd(chunk, ...args);
    };
  }

  return callback();
});

// Handle errors
// eslint-disable-next-line @typescript-eslint/no-explicit-any
mitmProxy.onError((_ctx: any, err: Error) => {
  console.error('[MITM] Proxy error:', err);
});

// =============================================================================
// START SERVERS
// =============================================================================

const activeAliases = aliasStore.aliases.filter(a => a.enabled);
const hosts = getUniqueHosts();

console.log(`
╔════════════════════════════════════════════════════════════════╗
║            Boardroom API Proxy Server (Alias Mode)             ║
╠════════════════════════════════════════════════════════════════╣
║  Admin UI:    http://0.0.0.0:${serverConfig.port}/admin${' '.repeat(30)}║
║  MITM Proxy:  http://0.0.0.0:${serverConfig.proxyPort}${' '.repeat(36)}║
║  Aliases:     ${ALIASES_FILE.padEnd(49)}║
╠════════════════════════════════════════════════════════════════╣
║  Active Aliases: ${activeAliases.length.toString().padEnd(3)} | Unique Hosts: ${hosts.length.toString().padEnd(23)}║
${activeAliases.length > 0
  ? activeAliases.slice(0, 5).map(a => `║    • ${a.alias.padEnd(30)} → ${a.host.padEnd(22)}║`).join('\n') + (activeAliases.length > 5 ? `\n║    ... and ${activeAliases.length - 5} more${' '.repeat(46)}║` : '')
  : '║    (no aliases configured - use Admin UI to add)            ║'}
╠════════════════════════════════════════════════════════════════╣
║  Usage: Set X-Key-Alias header to select specific alias        ║
║  Or configure default aliases per host in Admin UI             ║
╚════════════════════════════════════════════════════════════════╝
`);

// Start Hono server (admin + API)
serve({
  fetch: app.fetch,
  port: serverConfig.port,
});

// Start MITM proxy
mitmProxy.listen({
  host: '0.0.0.0',
  port: serverConfig.proxyPort,
  sslCaDir: certsDir,
}, () => {
  console.log(`[MITM] Proxy listening on port ${serverConfig.proxyPort}`);
  console.log(`[MITM] CA certificates stored in: ${certsDir}`);
});
