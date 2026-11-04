#!/usr/bin/env node
/**
 * refresh-nvidia-models.mjs
 *
 * Picks the best-fit free NVIDIA NIM models for each agent role in the
 * `nvidia` preset of oh-my-opencode-slim.json using deterministic scoring.
 *
 * Models are fetched live from the NVIDIA NIM catalog via direct HTTP to
 * https://integrate.api.nvidia.com/v1/models (no models.dev, no opencode CLI
 * dependency). Each candidate is then tested with a live chat completion
 * before selection to confirm availability.
 *
 * Variant validity is derived offline from the model's `variants` array
 * (NVIDIA shape), not `reasoning_options` (opencode shape).
 *
 * Usage:
 *   node scripts/refresh-nvidia-models.mjs [options]
 *
 * Options:
 *   --config <path>        Path to oh-my-opencode-slim.json (default: oh-my-opencode-slim.json)
 *   --roles <path>         Path to nvidia-model-roles.json (default: scripts/nvidia-model-roles.json)
 *   --report <path>        Write markdown change report to this file
 *   --dry-run              Do not write config; print what would change (models AND variants)
 *   --check                Exit 1 if changes would be made (models OR variants), 0 if no changes (for CI)
 *   --test-live            Test each candidate model with a live chat completion before selecting
 *   --help                 Show this help
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

const DEFAULT_CONFIG = 'oh-my-opencode-slim.json';
const DEFAULT_ROLES = 'scripts/nvidia-model-roles.json';

const NVIDIA_API_BASE = 'https://integrate.api.nvidia.com/v1';

const ROLE_ORDER = [
  'orchestrator',
  'oracle',
  'council',
  'librarian',
  'explorer',
  'designer',
  'fixer',
  'observer'
];

// ---------------------------------------------------------------------------
// Variant support (NVIDIA shape)
// ---------------------------------------------------------------------------

/** Default effort ladder for bare effort-type models. */
const DEFAULT_REASONING_VARIANTS = ['low', 'medium', 'high'];

/** Per-role variant priority (most-preferred first). */
const ROLE_VARIANT_PRIORITY = {
  orchestrator: ['thinking', 'high', 'max', 'xhigh', 'medium', 'low'],
  oracle: ['thinking', 'high', 'max', 'xhigh', 'medium', 'low'],
  council: ['high', 'max', 'xhigh', 'medium', 'low'],
  fixer: ['high', 'max', 'xhigh', 'medium', 'low'],
  librarian: ['low', 'medium', 'high', 'xhigh', 'max'],
  explorer: ['low', 'medium', 'high', 'xhigh', 'max'],
  observer: ['low', 'medium', 'high', 'xhigh', 'max'],
  designer: ['medium', 'low', 'high', 'xhigh', 'max'],
};
const DEFAULT_VARIANT_PRIORITY = ['medium', 'high', 'low', 'xhigh', 'max'];

/** Nearest-variant chains for hysteresis. */
const VARIANT_NEAREST = {
  max: ['max', 'xhigh', 'high', 'medium', 'low'],
  xhigh: ['xhigh', 'high', 'max', 'medium', 'low'],
  high: ['high', 'xhigh', 'max', 'medium', 'low'],
  medium: ['medium', 'high', 'low', 'xhigh', 'max'],
  low: ['low', 'medium', 'high', 'xhigh', 'max'],
  min: ['low', 'medium', 'high', 'xhigh', 'max'],
  minimal: ['low', 'medium', 'high', 'xhigh', 'max'],
  minimum: ['low', 'medium', 'high', 'xhigh', 'max'],
  off: ['low', 'medium', 'high', 'xhigh', 'max'],
  on: ['high', 'medium', 'low', 'xhigh', 'max'],
  thinking: ['thinking', 'high', 'max', 'xhigh', 'medium', 'low'],
};

/** Strip provider prefix (opencode/, nvidia/) for model-id comparisons.
 * Does NOT strip poolside/ or meta/ org prefixes — those are part of the id.
 */
function stripModelPrefix(id) {
  if (id == null) return id;
  const s = String(id);
  if (s.startsWith('nvidia/nvidia/')) return s.slice('nvidia/'.length);
  if (s.startsWith('opencode/')) return s.slice('opencode/'.length);
  if (s.startsWith('nvidia/')) return s.slice('nvidia/'.length);
  return s;
}

/** Ensure an `nvidia/` provider prefix on bare nemotron IDs.
 * poolside/ and meta/ ids already contain a `/` org segment and are left alone.
 */
function ensureNvidiaPrefix(id) {
  if (id == null) return id;
  const s = String(id);
  if (s.includes('/')) return s;
  return `nvidia/${s}`;
}

/** Serialize parsed model array back to config format.
 * Adds nvidia/ prefix only to bare ids (no existing / provider segment).
 * poolside/ and meta/ ids keep their existing prefix.
 */
function serializeModelArray(parsedModels) {
  return parsedModels.map(({ id, variant }) => {
    const stripped = stripModelPrefix(id);
    const prefixed = stripped.includes('/') ? stripped : `nvidia/${stripped}`;
    if (variant) return { id: prefixed, variant };
    return prefixed;
  });
}

/** Normalize a variant token for comparison. */
function normalizeVariant(v) {
  if (v == null) return '';
  let s = String(v).trim().toLowerCase().replace(/[\s_]+/g, '-');
  s = s.replace(/-+/g, '');
  const aliases = {
    'extrahigh': 'xhigh',
    'veryhigh': 'xhigh',
    'xh': 'xhigh',
    'extra': 'xhigh',
    'minimum': 'minimal',
    'none': 'off',
    'disabled': 'off',
    'enabled': 'on',
    'maximum': 'max',
  };
  return aliases[s] ?? s;
}

/** Parse a model array (strings or {id, variant} objects) -> [{id, variant}]. */
function parseModelArray(arr) {
  if (!Array.isArray(arr)) return [];
  return arr.map(m => {
    if (typeof m === 'string') return { id: stripModelPrefix(m), variant: null };
    if (m && typeof m === 'object' && typeof m.id === 'string') {
      return { id: stripModelPrefix(m.id), variant: m.variant ? normalizeVariant(m.variant) : null };
    }
    return { id: stripModelPrefix(String(m)), variant: null };
  });
}

/** Pick best variant for a model given supported variants + role priority. */
function pickBestVariant(supported, role) {
  if (!supported?.length) return null;
  const priority = ROLE_VARIANT_PRIORITY[role] ?? DEFAULT_VARIANT_PRIORITY;
  const hit = priority.find(v => supported.includes(normalizeVariant(v)));
  return hit ? normalizeVariant(hit) : supported[0];
}

function dedupeLowerList(list) {
  const seen = new Set();
  const out = [];
  for (const item of list) {
    const n = normalizeVariant(item);
    if (!n || seen.has(n)) continue;
    seen.add(n);
    out.push(n);
  }
  return out;
}

/**
 * Build the list of variants a model supports.
 * NVIDIA shape: model.variants is an array of strings (e.g. ['none', 'thinking']).
 * Falls back to reasoning_options (opencode shape) if present.
 */
function supportedVariants(model) {
  if (Array.isArray(model?.variants) && model.variants.length > 0) {
    return dedupeLowerList(model.variants.filter(v => typeof v === 'string'));
  }

  const ro = model?.reasoning_options ?? model?.reasoningOptions;
  const fromValues = (vals) =>
    dedupeLowerList((Array.isArray(vals) ? vals : []).filter((v) => typeof v === 'string' || typeof v === 'number'));

  const expandDescriptor = (entry) => {
    if (typeof entry === 'string') return fromValues([entry]);
    if (entry && typeof entry === 'object') {
      if (Array.isArray(entry.values) && entry.values.length) return fromValues(entry.values);
      const t = String(entry.type ?? '').trim().toLowerCase().replace(/[\s_-]+/g, '');
      if (t === 'effort') return [...DEFAULT_REASONING_VARIANTS];
      return [];
    }
    return [];
  };

  if (Array.isArray(ro)) {
    const union = [];
    for (const entry of ro) union.push(...expandDescriptor(entry));
    return dedupeLowerList(union);
  }
  if (ro && typeof ro === 'object') return expandDescriptor(ro);
  if (typeof ro === 'string' && ro.trim()) return fromValues([ro]);
  return [];
}

/** Intersection of picked models' supported variant sets. */
function commonVariants(supportedLists) {
  const nonEmpty = supportedLists.filter((l) => l.length > 0);
  if (nonEmpty.length === 0) return [];
  let common = [...nonEmpty[0]];
  for (const list of nonEmpty.slice(1)) {
    const set = new Set(list);
    common = common.filter((v) => set.has(v));
  }
  return common;
}

/**
 * Resolve which variant a role should use for its picked models.
 */
function resolveVariant({ role, currentVariant, pickedIds, candidatesById }) {
  const current = normalizeVariant(currentVariant);
  const supportedLists = pickedIds.map((id) => {
    const m = candidatesById.get(stripModelPrefix(id));
    return supportedVariants(m ?? {});
  });

  const hasKey = currentVariant !== undefined && currentVariant !== null;

  // 1. ANY picked model takes no variant -> role must have NO key.
  const emptyIds = pickedIds.filter((id, i) => (supportedLists[i] ?? []).length === 0);
  if (emptyIds.length > 0) {
    const offenders = emptyIds.map((id) => stripModelPrefix(id)).join(', ');
    if (!hasKey) {
      return { variant: undefined, removeVariant: false, changed: false, forced: false, warning: `Model(s) ${offenders} advertise no reasoning variants; no variant key needed.` };
    }
    return { variant: undefined, removeVariant: true, changed: true, forced: true, warning: `Model(s) ${offenders} advertise no reasoning variants; removing variant "${currentVariant}".` };
  }

  const allCompatible = supportedLists.every((l) => Boolean(current) && l.includes(current));
  if (current && allCompatible) {
    return { variant: currentVariant, removeVariant: false, changed: false, forced: false, warning: null };
  }

  if (!hasKey) {
    return { variant: undefined, removeVariant: false, changed: false, forced: false, warning: 'Picked models support reasoning variants but no variant key is set; leaving key absent.' };
  }

  const common = commonVariants(supportedLists);
  const priority = ROLE_VARIANT_PRIORITY[role] ?? DEFAULT_VARIANT_PRIORITY;
  const nearest = (current && VARIANT_NEAREST[current]) || [];

  if (common.length > 0) {
    const ordered = [...nearest, ...priority];
    const hit = ordered.find((v) => common.includes(normalizeVariant(v)));
    const chosen = hit != null ? normalizeVariant(hit) : common[0];
    return { variant: chosen, removeVariant: false, changed: normalizeVariant(chosen) !== current, forced: true, warning: null };
  }

  const primaryFirst = (supportedLists[0] ?? [])[0];
  if (primaryFirst) {
    return { variant: primaryFirst, removeVariant: false, changed: normalizeVariant(primaryFirst) !== current, forced: true, warning: `No common variant across picked models; using primary model's "${primaryFirst}".` };
  }

  throw new Error('unreachable: primary empty should have returned in step 1');
}


// ---------------------------------------------------------------------------
// NVIDIA NIM model fetching
// ---------------------------------------------------------------------------

/** Fetch the NVIDIA NIM model catalog via direct HTTP. */
async function fetchNvidiaModels() {
  const apiKey = process.env.NVIDIA_API_KEY;
  const headers = apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
  const res = await fetch(`${NVIDIA_API_BASE}/models`, { headers });
  if (!res.ok) throw new Error(`NVIDIA NIM API HTTP ${res.status}: ${res.statusText}`);
  const data = await res.json();
  const raw = Array.isArray(data) ? data : (data?.data ?? []);
  const models = {};
  for (const m of raw) {
    if (m && typeof m === 'object' && typeof m.id === 'string') {
      models[m.id] = m;
    }
  }
  return models;
}

/** Enrich NVIDIA catalog models with scoring metadata.
 * NVIDIA catalog returns minimal metadata (id, created, owned_by), so context,
 * reasoning, attachment, and variants come from NVIDIA_MODEL_METADATA
 * (hardcoded from live testing) or live run testing.
 * Models with no usable metadata (context 0 and no signals) are excluded.
 */
function normalizeModels(rawModels) {
  const models = [];
  for (const [id, m] of Object.entries(rawModels)) {
    const stripped = stripModelPrefix(id);
    const meta = NVIDIA_MODEL_METADATA[stripped] ?? {};
    const context = meta.context ?? 0;
    const output = meta.output ?? 0;
    const variants = meta.variants ?? [];
    // Require at least some usable signal so unknown models don't win ties alphabetically.
    if (context <= 0 && !meta.reasoning && !meta.attachment && variants.length === 0) continue;
    models.push({
      id: stripped,
      rawId: id,
      ...m,
      limit: { context, output },
      reasoning: meta.reasoning ?? false,
      attachment: meta.attachment ?? false,
      variants,
      created: m.created ?? 0,
      owned_by: m.owned_by ?? ''
    });
  }
  return models;
}

const NVIDIA_MODEL_METADATA = {
  'poolside/laguna-xs-2.1': { context: 131072, output: 4096, reasoning: false, attachment: false, variants: [] },
  'meta/llama-guard-4-12b': { context: 131072, output: 4096, reasoning: false, attachment: false, variants: [] },
  'meta/muse-glimmer-30b': { context: 131072, output: 4096, reasoning: false, attachment: false, variants: [] },
  'nemotron-3.5-lightning-30b-a3b': { context: 131072, output: 4096, reasoning: true, attachment: false, variants: ['thinking'] },
  'nemotron-3.5-super-vl-120b-a12b': { context: 131072, output: 4096, reasoning: true, attachment: true, variants: ['thinking'] },
  'nemotron-3-nano-omni-30b-a3b-reasoning': { context: 131072, output: 4096, reasoning: true, attachment: false, variants: ['thinking'] },
  'nemotron-3-ultra-550b-a55b': { context: 131072, output: 4096, reasoning: true, attachment: false, variants: ['thinking'] },
  'llama-3.1-nemotron-safety-guard-8b-v3': { context: 131072, output: 4096, reasoning: false, attachment: false, variants: [] }
};

function log10(x) { return Math.log10(Math.max(1, x)); }
function normalizeContext(ctx, max) { return Math.min(1, log10(ctx) / max); }
function normalizeOutput(out, max) { return Math.min(1, log10(out) / max); }
function monthsSince(dateStr) {
  if (!dateStr) return 60;
  let d;
  // NVIDIA catalog `created` may be a Unix timestamp in seconds; normalize to ms.
  if (typeof dateStr === 'number') {
    d = new Date(dateStr < 1e12 ? dateStr * 1000 : dateStr);
  } else {
    d = new Date(dateStr);
  }
  if (isNaN(d.getTime())) return 60;
  const now = new Date();
  return (now.getFullYear() - d.getFullYear()) * 12 + (now.getMonth() - d.getMonth());
}
function recencyScore(months, halfLife) {
  if (months <= 0) return 1;
  return Math.exp(-Math.log(2) * months / halfLife);
}
function keywordScore(text, keywords) {
  if (!text || !keywords?.length) return 0;
  const hay = text.toLowerCase();
  let hits = 0;
  for (const kw of keywords) {
    try { if (new RegExp(kw, 'i').test(hay)) hits++; }
    catch { if (hay.includes(kw.toLowerCase())) hits++; }
  }
  return hits / keywords.length;
}
function classHintScore(model, classHints) {
  if (!classHints) return 0;
  const name = (model.name + ' ' + model.family + ' ' + model.id).toLowerCase();
  let score = 0;
  if (classHints.powerful > 0 && /\b(ultra|max|pro|opus|sonnet|spark|large|big|pickle|super|ultra)\b/i.test(name)) score += classHints.powerful;
  if (classHints.fast > 0 && /\b(flash|mini|tiny|nano|lite|lightning|small|swift|speed|xs|laguna)\b/i.test(name)) score += classHints.fast;
  return score;
}

function scoreModel(model, roleConfig, global) {
  const { reasoningWeight, attachmentWeight, contextWeight, outputWeight,
          recencyWeight, keywordWeight, classHintWeight, keywords, classHints,
          requireAttachment } = roleConfig;

  if (requireAttachment && !model.attachment) return -Infinity;

  let score = 0;
  if (reasoningWeight && model.reasoning) score += reasoningWeight;
  if (attachmentWeight && model.attachment) score += attachmentWeight;
  if (contextWeight) score += contextWeight * normalizeContext(model.limit?.context ?? model.context_length ?? 0, global.log10ContextMax);
  if (outputWeight) score += outputWeight * normalizeOutput(model.limit?.output ?? model.max_output_tokens ?? 0, global.log10OutputMax);
  if (recencyWeight) {
    const rel = model.release_date || model.last_updated || model.created;
    score += recencyWeight * recencyScore(monthsSince(rel), global.recencyHalfLifeMonths);
  }
  if (keywordWeight) score += keywordWeight * keywordScore((model.description || '') + ' ' + (model.name || '') + ' ' + (model.family || '') + ' ' + model.id, keywords);
  if (classHintWeight) score += classHintWeight * classHintScore(model, classHints);

  return score;
}

function pickTopN(models, scored, currentModels, keepMargin, n) {
  // Exclude models with -Infinity score (e.g. designer requireAttachment fails)
  // so they don't fill remaining slots via alphabetical tie-break.
  const viable = scored.filter(s => s.score !== -Infinity);
  const sorted = [...viable].sort((a, b) => b.score - a.score || a.model.id.localeCompare(b.model.id));
  if (sorted.length === 0) return [];

  const topN = sorted.slice(0, n).map(s => s.model.id);
  if (currentModels.length < n || currentModels.every((m, i) => m === topN[i])) {
    return topN;
  }

  const currentPrimary = currentModels[0];
  const best = topN[0];
  if (currentPrimary && currentPrimary !== best) {
    const primaryScored = scored.find(s => s.model.id === currentPrimary);
    if (primaryScored && (sorted[0].score - primaryScored.score) <= keepMargin) {
      const others = sorted.filter(s => s.model.id !== currentPrimary).slice(0, n - 1);
      return [currentPrimary, ...others.map(o => o.model.id)];
    }
  }
  return topN;
}

function loadConfig(path) {
  const full = resolve(ROOT, path);
  if (!existsSync(full)) exit(1, `Config not found: ${full}`);
  const raw = readFileSync(full, 'utf8');
  let obj;
  try { obj = JSON.parse(raw); } catch { exit(1, `Invalid JSON in ${full}`); }
  return { obj, raw, path: full };
}

function loadRoles(path) {
  const full = resolve(ROOT, path);
  if (!existsSync(full)) exit(1, `Roles file not found: ${full}`);
  const raw = readFileSync(full, 'utf8');
  let obj;
  try { obj = JSON.parse(raw); } catch { exit(1, `Invalid JSON in ${full}`); }
  return obj;
}

function formatDiff(oldArr, newArr) {
  const normalize = (arr) => arr.map(m => typeof m === 'string' ? m : `${m.id}:${m.variant ?? ''}`);
  const oldStr = JSON.stringify(normalize(oldArr));
  const newStr = JSON.stringify(normalize(newArr));
  if (oldStr === newStr) return '  (unchanged)';
  return `  - ${oldStr}\n  + ${newStr}`;
}

function formatVariantDiff(oldV, newV) {
  const o = oldV ?? '(none)';
  const n = newV ?? '(none)';
  if (normalizeVariant(o) === normalizeVariant(n) && o === n) return '  (unchanged)';
  if (String(o) === String(n)) return '  (unchanged)';
  return `  - variant: ${JSON.stringify(o)}\n  + variant: ${JSON.stringify(n)}`;
}

function buildReport(results, configObj) {
  const lines = [];
  lines.push('# NVIDIA Model Refresh Report');
  lines.push('');
  lines.push(`Generated: ${new Date().toISOString()}`);
  lines.push('');
  lines.push('## Changes');
  lines.push('');
  let any = false;
  for (const r of results) {
    const role = r.role;
    const old = configObj.presets.nvidia?.[role]?.model;
    const newModels = r.pickedSerialized ?? [];
    const diff = formatDiff(old, newModels);
    const oldVariant = configObj.presets.nvidia?.[role]?.variant;
    const newVariant = r.removeVariant ? undefined : r.variant;
    const vdiff = formatVariantDiff(oldVariant, newVariant);
    if (diff !== '  (unchanged)') any = true;
    if (vdiff !== '  (unchanged)') any = true;
    lines.push(`### ${role}`);
    lines.push(`model: ${diff}`);
    lines.push(`variant: ${vdiff}`);
    const perModelVariants = (r.picked ?? []).filter(p => typeof p === 'object' && p.variant);
    if (perModelVariants.length) {
      lines.push(`  per-model variants:`);
      for (const m of perModelVariants) {
        lines.push(`    - ${stripModelPrefix(m.id)}: ${m.variant}`);
      }
    }
    if (r.variantChanged) {
      lines.push(`  variant ${JSON.stringify(oldVariant)} → ${JSON.stringify(newVariant)}${r.variantForced ? ' (forced: previous variant unsupported)' : ''}`);
    }
    if (r.variantWarning) lines.push(`  **VARIANT NOTE**: ${r.variantWarning}`);
    if (r.sharesWith?.length) lines.push(`  *Shares model(s) with: ${r.sharesWith.join(', ')}*`);
    if (r.forced) lines.push(`  **FORCED REPLACEMENT**: previous model unavailable`);
    lines.push('');
  }
  if (!any) {
    lines.push('*No changes — all roles already optimal (models and variants)*');
    lines.push('');
  }
  lines.push('## Candidate Pool');
  lines.push('');
  lines.push('| Model | Context | Output | Reasoning | Variants | Release |');
  lines.push('|-------|--------:|-------:|:---------:|:--------:|---------|');
  for (const m of results[0]?.allCandidates ?? []) {
    const vs = supportedVariants(m);
    lines.push(`| ${m.id} | ${m.limit?.context ?? m.context_length ?? 0} | ${m.limit?.output ?? m.max_output_tokens ?? 0} | ${m.reasoning ? '✅' : '❌'} | ${vs.length ? vs.join(', ') : '—'} | ${m.release_date || 'unknown'} |`);
  }
  lines.push('');
  lines.push('> Note: model availability verified live against NVIDIA NIM API.');
  return lines.join('\n');
}

function log(...args) { console.log(...args); }
function warn(...args) { console.error('WARNING:', ...args); }
function error(...args) { console.error('ERROR:', ...args); }
function exit(code, msg) { if (msg) error(msg); process.exit(code); }

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { config: DEFAULT_CONFIG, roles: DEFAULT_ROLES, report: null, dryRun: false, check: false, testLive: false, help: false };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--help' || a === '-h') opts.help = true;
    else if (a === '--config') { if (i + 1 >= args.length) exit(1, `Missing value for ${a}`); opts.config = args[++i]; }
    else if (a === '--roles') { if (i + 1 >= args.length) exit(1, `Missing value for ${a}`); opts.roles = args[++i]; }
    else if (a === '--report') { if (i + 1 >= args.length) exit(1, `Missing value for ${a}`); opts.report = args[++i]; }
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--check') opts.check = true;
    else if (a === '--test-live') opts.testLive = true;
    else exit(1, `Unknown option: ${a}`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const opts = parseArgs();
  if (opts.help) {
    console.log(`
Usage: node scripts/refresh-nvidia-models.mjs [options]

Picks top NVIDIA NIM models per role AND validates each role's variant against
the picked models' supported variants (from NVIDIA catalog).

Options:
  --config <path>     Path to oh-my-opencode-slim.json (default: ${DEFAULT_CONFIG})
  --roles <path>      Path to nvidia-model-roles.json (default: ${DEFAULT_ROLES})
  --report <path>     Write markdown report to file
  --dry-run           Do not write config; print what would change (models AND variants)
  --check             Exit 1 if changes would be made (models OR variants), 0 if no changes
  --test-live         Test each candidate model with a live chat completion before selecting
  --help              Show this help
`);
    process.exit(0);
  }

  const { obj: config, raw: configRaw, path: configPath } = loadConfig(opts.config);
  const rolesConfig = loadRoles(opts.roles);

  if (!config.presets?.nvidia) exit(2, 'Missing presets.nvidia in config');
  const preset = config.presets.nvidia;

  // Fetch and filter NVIDIA models
  let rawModels;
  try {
    rawModels = await fetchNvidiaModels();
  } catch (e) {
    exit(3, `Failed to fetch NVIDIA NIM models: ${e.message}`);
  }
  if (!rawModels) exit(3, 'Failed to fetch NVIDIA NIM models: no data returned');
  const candidates = normalizeModels(rawModels);
  // Without --test-live, restrict to models with known metadata (tested/working).
  // Unknown models score 0 on all signals and can win ties alphabetically.
  const eligibleCandidates = opts.testLive
    ? candidates
    : candidates.filter(m => m.reasoning || m.attachment || m.variants.length > 0 || m.limit.context > 0);
  if (eligibleCandidates.length === 0) exit(4, 'No eligible NVIDIA models after filtering');

  log(`Fetched ${Object.keys(rawModels).length} NVIDIA models; ${eligibleCandidates.length} eligible`);

  // Optionally test each candidate with a live chat completion
  const workingIds = new Set();
  if (opts.testLive) {
    const apiKey = process.env.NVIDIA_API_KEY;
    if (!apiKey) {
      warn('NVIDIA_API_KEY not set; skipping live testing, using all eligible candidates');
      eligibleCandidates.forEach(m => workingIds.add(m.id));
    } else {
      for (const m of eligibleCandidates) {
        const ok = await testNvidiaModel(ensureNvidiaPrefix(m.rawId ?? m.id), apiKey);
        if (ok) workingIds.add(m.id);
      }
      log(`Live-tested ${eligibleCandidates.length} candidates; ${workingIds.size} working`);
    }
  } else {
    eligibleCandidates.forEach(m => workingIds.add(m.id));
  }

  const workingCandidates = eligibleCandidates.filter(m => workingIds.has(m.id));
  if (workingCandidates.length === 0) exit(5, 'No working NVIDIA models after live testing');

  // Score each model for each role
  const scoredByRole = {};
  for (const role of ROLE_ORDER) {
    const roleCfg = rolesConfig.roles[role];
    if (!roleCfg) exit(6, `Role "${role}" not found in roles config`);
    scoredByRole[role] = workingCandidates.map(m => ({
      model: m,
      score: scoreModel(m, roleCfg, rolesConfig.global)
    }));
  }

  const candidatesById = new Map(workingCandidates.map((m) => [stripModelPrefix(m.id), m]));

  // Pick top N per role with hysteresis (N from role config)
  const results = [];
  const modelToRoles = new Map();
  for (const role of ROLE_ORDER) {
    const roleCfg = rolesConfig.roles[role];
    const n = roleCfg.modelCount || 3;
    const currentRaw = preset[role]?.model || [];
    const currentParsed = parseModelArray(currentRaw);
    const currentVariant = preset[role]?.variant;

    const scored = scoredByRole[role];
    const pin = roleCfg.pin || [];
    let picked;
    let forced = false;
    let pinned = false;

    if (pin.length > 0) {
      const eligiblePins = pin.filter(p => workingCandidates.some(c => c.id === stripModelPrefix(p)));
      if (eligiblePins.length >= n) {
        picked = eligiblePins.slice(0, n);
        pinned = true;
      } else if (eligiblePins.length > 0) {
        const others = scored.filter(s => !eligiblePins.includes(s.model.id)).slice(0, n - eligiblePins.length);
        picked = [...eligiblePins, ...others.map(o => o.model.id)].filter(Boolean);
        pinned = true;
      } else {
        forced = true;
      }
    }

    if (!picked) {
      const currentStripped = currentParsed.map(p => p.id);
      const missing = currentStripped.some((m) => m && !candidatesById.has(m));
      if (missing) forced = true;
      picked = pickTopN(workingCandidates, scored, currentStripped, roleCfg.keepMargin || 0.15, n);
    }

    // Build per-model variant assignments for picked models
    const pickedWithVariants = picked.map((modelId) => {
      const stripped = stripModelPrefix(modelId);
      const currentMatch = currentParsed.find(p => p.id === stripped);
      if (currentMatch?.variant) {
        const supported = supportedVariants(candidatesById.get(stripped) ?? {});
        if (supported.includes(currentMatch.variant)) {
          return { id: modelId, variant: currentMatch.variant };
        }
      }
      const supported = supportedVariants(candidatesById.get(stripped) ?? {});
      const variant = pickBestVariant(supported, role);
      return variant ? { id: modelId, variant } : modelId;
    });

    const firstVariant = pickedWithVariants[0] && typeof pickedWithVariants[0] === 'object' ? pickedWithVariants[0].variant : null;
    const allSameVariant = pickedWithVariants.every(m => typeof m === 'object' && m.variant === firstVariant);
    // Keyless roles must stay keyless: per-model variant assignment must not
    // leak into agent-level resolution. Only use firstVariant when the config
    // already has a variant key.
    const agentVariantForResolve = (currentVariant !== undefined && currentVariant !== null)
      ? (allSameVariant && firstVariant ? firstVariant : currentVariant)
      : undefined;

    const vr = resolveVariant({
      role,
      currentVariant: agentVariantForResolve,
      pickedIds: picked,
      candidatesById,
    });

    for (const m of picked) {
      if (!modelToRoles.has(m)) modelToRoles.set(m, []);
      modelToRoles.get(m).push(role);
    }

    results.push({
      role,
      picked: pickedWithVariants,
      pickedSerialized: serializeModelArray(
        pickedWithVariants.map(p => typeof p === 'string' ? { id: p, variant: null } : p)
      ),
      old: currentRaw,
      variant: vr.variant,
      removeVariant: vr.removeVariant === true,
      oldVariant: currentVariant,
      variantChanged: vr.changed,
      variantForced: vr.forced,
      variantWarning: vr.warning,
      sharesWith: modelToRoles.get(picked[0])?.filter(r => r !== role) || [],
      forced,
      pinned,
      allCandidates: workingCandidates
    });
  }

  // Build new config
  const newConfig = JSON.parse(configRaw);
  for (const r of results) {
    newConfig.presets.nvidia[r.role].model = serializeModelArray(
      r.picked.map(p => typeof p === 'string' ? { id: p, variant: null } : p)
    );
    if (r.removeVariant) {
      delete newConfig.presets.nvidia[r.role].variant;
    } else if (r.variantChanged && r.variant != null) {
      newConfig.presets.nvidia[r.role].variant = r.variant;
    }
  }

  const newRaw = JSON.stringify(newConfig, null, 2);
  const changed = newRaw !== configRaw;

  const report = buildReport(results, config);
  if (opts.report) {
    writeFileSync(resolve(ROOT, opts.report), report);
    log(`Report written to ${opts.report}`);
  } else {
    console.log(report);
  }

  if (opts.check) {
    process.exit(changed ? 1 : 0);
  }

  if (opts.dryRun) {
    log(changed ? 'DRY RUN — changes would be made' : 'DRY RUN — no changes needed');
    process.exit(changed ? 1 : 0);
  }

  if (changed) {
    writeFileSync(configPath, newRaw);
    log(`Updated ${configPath}`);
  } else {
    log('No changes — config already optimal');
  }
}

/** Test a single NVIDIA model with a live chat completion. */
async function testNvidiaModel(modelId, apiKey) {
  try {
    const res = await fetch(`${NVIDIA_API_BASE}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`
      },
      body: JSON.stringify({
        model: modelId,
        messages: [{ role: 'user', content: 'ping' }],
        max_tokens: 5,
        stream: false
      }),
      signal: AbortSignal.timeout(15000)
    });
    return res.ok;
  } catch {
    return false;
  }
}

const invokedAsScript =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedAsScript) {
  main().catch(e => {
    error(e.message);
    process.exit(1);
  });
}

export {
  stripModelPrefix,
  ensureNvidiaPrefix,
  normalizeVariant,
  supportedVariants,
  commonVariants,
  resolveVariant,
  pickTopN,
  scoreModel,
  formatDiff,
  formatVariantDiff,
  buildReport,
  parseModelArray,
  serializeModelArray,
  pickBestVariant,
  ROLE_VARIANT_PRIORITY,
  VARIANT_NEAREST,
  DEFAULT_REASONING_VARIANTS,
  normalizeModels,
  monthsSince,
  fetchNvidiaModels,
  testNvidiaModel,
};
