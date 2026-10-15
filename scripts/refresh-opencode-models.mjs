#!/usr/bin/env node
/**
 * refresh-opencode-models.mjs
 *
 * Picks the best-fit free opencode models for each agent role in the
 * `opencode` preset of oh-my-opencode-slim.json using deterministic scoring.
 *
 * Also validates/resolves each role's static `variant` against the picked
 * models' advertised reasoning options ("test all existed and available
 * model with its variant updating the new variant").
 *
 * Variant validity is derived OFFLINE from models.dev static metadata
 * (`reasoning` + `reasoning_options`) — no live `opencode run` calls are
 * made. This keeps CI deterministic, credential-free, and network-light
 * (one models.dev fetch). A live run-matrix would be non-deterministic,
 * slow, and require provider auth, so the static check is the intended
 * interpretation of "test all existed and available" in a CI context.
 *
 * Usage:
 *   node scripts/refresh-opencode-models.mjs [options]
 *
 * Options:
 *   --config <path>        Path to oh-my-opencode-slim.json (default: oh-my-opencode-slim.json)
 *   --roles <path>         Path to opencode-model-roles.json (default: scripts/opencode-model-roles.json)
 *   --report <path>        Write markdown change report to this file
 *   --dry-run              Do not write config; print what would change (models AND variants)
 *   --check                Exit 1 if changes would be made (models OR variants), 0 if no changes (for CI)
 *   --help                 Show this help
 */

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..');

const DEFAULT_CONFIG = 'oh-my-opencode-slim.json';
const DEFAULT_ROLES = 'scripts/opencode-model-roles.json';

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
// Variant support
// ---------------------------------------------------------------------------

/** Default effort ladder for bare `type: 'effort'` (mirrors opencode default _i). */
const DEFAULT_REASONING_VARIANTS = ['low', 'medium', 'high'];

/**
 * Per-role variant priority (most-preferred first). Used as the fallback
 * order when the current preset variant is invalid for the picked models.
 * - Deep-reasoning roles want high effort first.
 * - Fast/cheap roles want low effort first.
 * - Designer wants a balanced default.
 */
const ROLE_VARIANT_PRIORITY = {
  orchestrator: ['high', 'max', 'xhigh', 'medium', 'low'],
  oracle: ['high', 'max', 'xhigh', 'medium', 'low'],
  council: ['high', 'max', 'xhigh', 'medium', 'low'],
  fixer: ['high', 'max', 'xhigh', 'medium', 'low'],
  librarian: ['low', 'medium', 'high', 'xhigh', 'max'],
  explorer: ['low', 'medium', 'high', 'xhigh', 'max'],
  observer: ['low', 'medium', 'high', 'xhigh', 'max'],
  designer: ['medium', 'low', 'high', 'xhigh', 'max'],
};
const DEFAULT_VARIANT_PRIORITY = ['medium', 'high', 'low', 'xhigh', 'max'];

/**
 * Nearest-variant chains: when the current preset variant is invalid for
 * the newly picked models, try these neighbours first (hysteresis for the
 * variant dimension) before falling back to the role priority list.
 * e.g. max -> xhigh -> high; minimal/min/off -> low.
 */
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

/** Strip the `opencode/` provider prefix for models.dev comparisons. */
function stripModelPrefix(id) {
  if (id == null) return id;
  const s = String(id);
  return s.startsWith('opencode/') ? s.slice('opencode/'.length) : s;
}

/**
 * Normalize a variant token for comparison.
 * Lowercases, trims, removes separators, and maps known aliases:
 * extra-high/very-high/x-high -> xhigh, minimal/minimum/none -> low-ish.
 */
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
 * Build the list of variants a model supports, mirroring opencode runtime
 * (authoritative: fx + VO/Ya for the opencode provider).
 *
 * Rules:
 * - reasoning_options as array of descriptors/string literals:
 *   string entries are literal variant values; object entries with
 *   explicit `values` contribute those values verbatim (normalized);
 *   `{type:'effort'}` without values contributes ['low','medium','high']
 *   (opencode default _i); every other object without values
 *   (toggle/boolean/switch, budget_tokens/budget/tokens/max_tokens,
 *   unknown types) contributes NOTHING. Union all contributions.
 *   Empty array / missing / {} -> [] (opencode fx(e,[]) -> []).
 * - reasoning_options as single object: explicit `values` -> verbatim;
 *   bare `{type:'effort'}` -> ['low','medium','high']; anything else
 *   (toggle, budget_*, empty {}, unknown) -> [].
 * - missing/null/'' or any other shape -> [] regardless of `reasoning`.
 *
 * NOTE: the `reasoning` boolean does NOT invent variants. A model with
 * reasoning:true but no usable reasoning_options takes NO variant.
 */
function supportedVariants(model) {
  const ro = model?.reasoning_options ?? model?.reasoningOptions;

  const fromValues = (vals) =>
    dedupeLowerList((Array.isArray(vals) ? vals : []).filter((v) => typeof v === 'string' || typeof v === 'number'));

  const bareEffortLadder = () => [...DEFAULT_REASONING_VARIANTS];

  const expandDescriptor = (entry) => {
    if (typeof entry === 'string') return fromValues([entry]);
    if (entry && typeof entry === 'object') {
      if (Array.isArray(entry.values) && entry.values.length) {
        return fromValues(entry.values);
      }
      const t = String(entry.type ?? '').trim().toLowerCase().replace(/[\s_-]+/g, '');
      if (t === 'effort') return bareEffortLadder();
      // toggle/boolean/switch (Ya() returns [] for non-effort type),
      // budget_tokens/budget/tokens/max_tokens, unknown types, and
      // typeless objects all contribute nothing.
      return [];
    }
    return [];
  };

  if (Array.isArray(ro)) {
    // models.dev shape: ARRAY of descriptors,
    // e.g. [{type:"toggle"}] or [{type:"effort",values:[...]}].
    const union = [];
    for (const entry of ro) {
      union.push(...expandDescriptor(entry));
    }
    return dedupeLowerList(union);
  }

  if (ro && typeof ro === 'object') {
    return expandDescriptor(ro);
  }

  if (typeof ro === 'string' && ro.trim()) {
    return fromValues([ro]);
  }

  return [];
}

/**
 * Intersection of picked models' supported variant sets.
 * Only ever receives non-empty inputs: resolveVariant step 1 returns early
 * whenever ANY picked model advertises no variants ([]), so every list here
 * is non-empty. Simply intersects them. The empty-input guard returning []
 * is retained as a defensive precondition only.
 */
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
 *
 * @param {object} args - { role, currentVariant, pickedIds, candidatesById }
 *   pickedIds are prefix-stripped model ids; candidatesById maps stripped
 *   id -> model object (with reasoning/reasoning_options).
 * @returns {{ variant, removeVariant, changed, forced, warning }} When
 *   `removeVariant` is true, the caller must DELETE the role's variant key
 *   (the resolved `variant` is undefined). Otherwise `variant` is the
 *   resolved (normalized) variant string, or the current value when kept.
 *
 * Logic:
 * 1. If ANY picked model advertises no variants ([]) -> the role must
 *    have NO variant key. Omitting a variant always passes at runtime,
 *    while any non-empty variant fails on a [] model, so a key is only
 *    safe when EVERY picked model supports variants. With no key present
 *    -> no change (variant undefined, changed false, warning notes no key
 *    is needed). With a key present -> remove it (removeVariant true,
 *    changed true, forced true, warning names the offending model id(s)
 *    and notes the fallback model advertises no variants). This subsumes
 *    the primary-empty and all-empty cases.
 * 2. If current variant is valid for ALL picked models -> keep it
 *    (hysteresis), no change. (Unreachable with [] present: step 1
 *    returned already, so every list is non-empty here.)
 * 3. If no variant key is set (currentVariant undefined/null) -> NEVER
 *    auto-add: return no change (variant undefined, changed false,
 *    forced false, warning notes supporting models exist but the key is
 *    absent). Omitting is always safe, so a keyless role stays keyless.
 * 4. Else (key present, invalid) fallback: nearest-chain(current) ++
 *    role-priority, first hit in the common intersection. Marks
 *    forced=true, changed=true.
 * 5. If the common intersection is empty -> use the primary model's first
 *    supported value (forced + warning). Primary is guaranteed non-empty
 *    here (step 1 returned otherwise), so this always yields a value.
 */
function resolveVariant({ role, currentVariant, pickedIds, candidatesById }) {
  const current = normalizeVariant(currentVariant);
  const supportedLists = pickedIds.map((id) => {
    const m = candidatesById.get(stripModelPrefix(id));
    return supportedVariants(m ?? {});
  });

  const hasKey = currentVariant !== undefined && currentVariant !== null;

  // 1. ANY picked model takes no variant -> the role must have NO key.
  // Omitting always passes; any non-empty variant fails on a [] model
  // (including fallback models), so a key is only safe when EVERY model
  // supports variants. This subsumes the primary-empty / all-empty cases.
  const emptyIds = pickedIds.filter((id, i) => (supportedLists[i] ?? []).length === 0);
  if (emptyIds.length > 0) {
    const offenders = emptyIds.map((id) => stripModelPrefix(id)).join(', ');
    if (!hasKey) {
      return {
        variant: undefined,
        removeVariant: false,
        changed: false,
        forced: false,
        warning: `Model(s) ${offenders} advertise(s) no reasoning variants; no variant key needed (omitting is always safe).`,
      };
    }
    return {
      variant: undefined,
      removeVariant: true,
      changed: true,
      forced: true,
      warning: `Model(s) ${offenders} advertise(s) no reasoning variants; fallback model advertises no variants; removing variant "${currentVariant}" (variant not supported).`,
    };
  }

  const allCompatible = supportedLists.every(
    (l) => Boolean(current) && l.includes(current)
  );
  if (current && allCompatible) {
    return { variant: currentVariant, removeVariant: false, changed: false, forced: false, warning: null };
  }

  // 3. Keyless roles stay keyless: omitting is always safe, so never
  // auto-add a variant from ROLE_VARIANT_PRIORITY. Applies to both the
  // common-intersection branch and the primary-first fallback below.
  if (!hasKey) {
    return {
      variant: undefined,
      removeVariant: false,
      changed: false,
      forced: false,
      warning: 'Picked models support reasoning variants but no variant key is set; leaving key absent (omitting is always safe).',
    };
  }

  const common = commonVariants(supportedLists);
  const priority = ROLE_VARIANT_PRIORITY[role] ?? DEFAULT_VARIANT_PRIORITY;
  const nearest = (current && VARIANT_NEAREST[current]) || [];

  if (common.length > 0) {
    const ordered = [...nearest, ...priority];
    const hit = ordered.find((v) => common.includes(normalizeVariant(v)));
    const chosen = hit != null ? normalizeVariant(hit) : common[0];
    // Preserve the original casing style? Variants are lowercase by
    // convention, so emit the normalized lowercase token.
    const changed = normalizeVariant(chosen) !== current;
    return {
      variant: chosen,
      removeVariant: false,
      changed,
      forced: true,
      warning: null,
    };
  }

  // Empty intersection: fall back to the primary model's first value.
  // Primary is guaranteed non-empty here (step 1 handled the empty case).
  const primaryFirst = (supportedLists[0] ?? [])[0];
  if (primaryFirst) {
    return {
      variant: primaryFirst,
      removeVariant: false,
      changed: normalizeVariant(primaryFirst) !== current,
      forced: true,
      warning: `No common variant across picked models; using primary model's "${primaryFirst}".`,
    };
  }

  throw new Error('unreachable: primary empty should have returned in step 1');
}

function log(...args) {
  console.log(...args);
}

function warn(...args) {
  console.error('WARNING:', ...args);
}

function error(...args) {
  console.error('ERROR:', ...args);
}

function exit(code, msg) {
  if (msg) error(msg);
  process.exit(code);
}

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    config: DEFAULT_CONFIG,
    roles: DEFAULT_ROLES,
    report: null,
    dryRun: false,
    check: false,
    help: false
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--help' || a === '-h') opts.help = true;
    else if (a === '--config') opts.config = args[++i];
    else if (a === '--roles') opts.roles = args[++i];
    else if (a === '--report') opts.report = args[++i];
    else if (a === '--dry-run') opts.dryRun = true;
    else if (a === '--check') opts.check = true;
    else exit(1, `Unknown option: ${a}`);
  }
  return opts;
}

async function fetchModelsDev(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`models.dev HTTP ${res.status}: ${res.statusText}`);
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); }
  catch { throw new Error('models.dev returned invalid JSON'); }
  return data;
}

function filterModels(rawModels) {
  const models = [];
  for (const [id, m] of Object.entries(rawModels)) {
    const costIn = m.cost?.input ?? 1;
    const costOut = m.cost?.output ?? 1;
    const deprecated = m.status === 'deprecated';
    const toolCall = m.tool_call === true;
    const context = m.limit?.context ?? 0;
    if (costIn === 0 && costOut === 0 && !deprecated && toolCall && context > 0) {
      models.push({ id, ...m });
    }
  }
  return models;
}

function log10(x) {
  return Math.log10(Math.max(1, x));
}

function normalizeContext(ctx, max) {
  return Math.min(1, log10(ctx) / max);
}

function normalizeOutput(out, max) {
  return Math.min(1, log10(out) / max);
}

function monthsSince(dateStr) {
  if (!dateStr) return 60;
  const d = new Date(dateStr);
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
    try {
      if (new RegExp(kw, 'i').test(hay)) hits++;
    } catch {
      if (hay.includes(kw.toLowerCase())) hits++;
    }
  }
  return hits / keywords.length;
}

function classHintScore(model, classHints) {
  if (!classHints) return 0;
  const name = (model.name + ' ' + model.family + ' ' + model.id).toLowerCase();
  let score = 0;
  if (classHints.powerful > 0) {
    const powerful = /\b(ultra|max|pro|opus|sonnet|spark|large|big|pickle)\b/i;
    if (powerful.test(name)) score += classHints.powerful;
  }
  if (classHints.fast > 0) {
    const fast = /\b(flash|mini|tiny|nano|lite|lightning|small|swift|speed)\b/i;
    if (fast.test(name)) score += classHints.fast;
  }
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
  if (contextWeight) score += contextWeight * normalizeContext(model.limit?.context, global.log10ContextMax);
  if (outputWeight) score += outputWeight * normalizeOutput(model.limit?.output, global.log10OutputMax);
  if (recencyWeight) {
    const rel = model.release_date || model.last_updated;
    score += recencyWeight * recencyScore(monthsSince(rel), global.recencyHalfLifeMonths);
  }
  if (keywordWeight) score += keywordWeight * keywordScore(model.description + ' ' + model.name + ' ' + model.family, keywords);
  if (classHintWeight) score += classHintWeight * classHintScore(model, classHints);

  return score;
}

function pickTopN(models, scored, currentModels, keepMargin, n) {
  const sorted = [...scored].sort((a, b) => b.score - a.score);
  if (sorted.length === 0) return [];

  // Return up to n models, or all available if fewer
  const topN = sorted.slice(0, n).map(s => s.model.id);
  if (currentModels.length < n || currentModels.every((m, i) => m === topN[i])) {
    return topN;
  }

  // Hysteresis: keep current primary if it's within margin of best
  const currentPrimary = currentModels[0];
  const best = topN[0];
  if (currentPrimary && currentPrimary !== best) {
    const primaryScored = scored.find(s => s.model.id === currentPrimary);
    if (primaryScored && (sorted[0].score - primaryScored.score) <= keepMargin) {
      // Keep current primary, fill rest with best different models
      const others = scored.filter(s => s.model.id !== currentPrimary).slice(0, n - 1);
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
  try { obj = JSON.parse(raw); }
  catch { exit(1, `Invalid JSON in ${full}`); }
  return { obj, raw, path: full };
}

function loadRoles(path) {
  const full = resolve(ROOT, path);
  if (!existsSync(full)) exit(1, `Roles file not found: ${full}`);
  const raw = readFileSync(full, 'utf8');
  let obj;
  try { obj = JSON.parse(raw); }
  catch { exit(1, `Invalid JSON in ${full}`); }
  return obj;
}

function formatDiff(oldArr, newArr) {
  const oldStr = JSON.stringify(oldArr);
  const newStr = JSON.stringify(newArr);
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
  lines.push('# Opencode Model Refresh Report');
  lines.push('');
  lines.push(`Generated: ${new Date().toISOString()}`);
  lines.push('');
  lines.push('## Changes');
  lines.push('');
  let any = false;
  for (const r of results) {
    const role = r.role;
    const old = configObj.presets.opencode[role].model;
    // Normalize both sides to prefixed IDs so unchanged models show
    // unchanged (picked may be stripped while config stores prefixed).
    const newModels = (r.picked ?? []).map((m) => `opencode/${stripModelPrefix(m)}`);
    const diff = formatDiff(old, newModels);
    const oldVariant = configObj.presets.opencode[role].variant;
    const newVariant = r.removeVariant ? undefined : r.variant;
    const vdiff = formatVariantDiff(oldVariant, newVariant);
    if (diff !== '  (unchanged)') any = true;
    if (vdiff !== '  (unchanged)') any = true;
    lines.push(`### ${role}`);
    lines.push(`model: ${diff}`);
    lines.push(`variant: ${vdiff}`);
    if (r.variantChanged) {
      lines.push(`  variant ${JSON.stringify(oldVariant)} → ${JSON.stringify(newVariant)}${r.variantForced ? ' (forced: previous variant unsupported by picked models)' : ''}`);
    }
    if (r.variantWarning) {
      lines.push(`  **VARIANT NOTE**: ${r.variantWarning}`);
    }
    if (r.sharesWith?.length) {
      lines.push(`  *Shares model(s) with: ${r.sharesWith.join(', ')}*`);
    }
    if (r.forced) {
      lines.push(`  **FORCED REPLACEMENT**: previous model deprecated/missing`);
    }
    if (r.pinned) {
      lines.push(`  **PINNED**: using user-specified model`);
    }
    lines.push('');
  }
  if (!any) {
    lines.push('*No changes — all roles already optimal (models and variants)*');
    lines.push('');
  }
  lines.push('## Candidate Pool');
  lines.push('');
  lines.push('| Model | Context | Output | Attachment | Reasoning | Variants | Release |');
  lines.push('|-------|--------:|-------:|:----------:|:---------:|:--------:|--------|');
  for (const m of results[0].allCandidates) {
    const vs = supportedVariants(m);
    lines.push(`| ${m.id} | ${m.limit.context.toLocaleString()} | ${m.limit.output.toLocaleString()} | ${m.attachment ? '✅' : '❌'} | ${m.reasoning ? '✅' : '❌'} | ${vs.length ? vs.join(', ') : '—'} | ${m.release_date || 'unknown'} |`);
  }
  lines.push('');
  lines.push('> Note: variant validity is checked offline against models.dev static');
  lines.push('> `reasoning` + `reasoning_options` metadata (no live `opencode run`');
  lines.push('> calls), so CI stays deterministic and credential-free.');
  return lines.join('\n');
}

async function main() {
  const opts = parseArgs();
  if (opts.help) {
    console.log(`
Usage: node scripts/refresh-opencode-models.mjs [options]

Picks top models per role AND validates each role's variant against the
picked models' supported variants (from models.dev reasoning_options).

Options:
  --config <path>     Path to oh-my-opencode-slim.json (default: ${DEFAULT_CONFIG})
  --roles <path>      Path to opencode-model-roles.json (default: ${DEFAULT_ROLES})
  --report <path>     Write markdown report to file
  --dry-run           Do not write config; print what would change (models AND variants)
  --check             Exit 1 if changes would be made (models OR variants), 0 if no changes
  --help              Show this help
`);
    process.exit(0);
  }

  const { obj: config, raw: configRaw, path: configPath } = loadConfig(opts.config);
  const rolesConfig = loadRoles(opts.roles);

  if (!config.presets?.opencode) exit(2, 'Missing presets.opencode in config');
  const preset = config.presets.opencode;

  // Fetch and filter models
  let rawModels;
  try {
    const data = await fetchModelsDev(rolesConfig.global.modelsDevUrl);
    rawModels = data[rolesConfig.global.provider]?.models;
    if (!rawModels) exit(3, `Provider "${rolesConfig.global.provider}" not found in models.dev`);
  } catch (e) {
    exit(3, `Failed to fetch models.dev: ${e.message}`);
  }

  const candidates = filterModels(rawModels);
  if (candidates.length === 0) exit(4, 'No eligible models after filtering (free, non-deprecated, tool_call, context>0)');

  log(`Fetched ${Object.keys(rawModels).length} opencode models; ${candidates.length} eligible (free, active, tool_call, context>0)`);

  // Score each model for each role
  const scoredByRole = {};
  for (const role of ROLE_ORDER) {
    const roleCfg = rolesConfig.roles[role];
    if (!roleCfg) exit(5, `Role "${role}" not found in roles config`);
    scoredByRole[role] = candidates.map(m => ({
      model: m,
      score: scoreModel(m, roleCfg, rolesConfig.global)
    }));
  }

  const candidatesById = new Map(candidates.map((m) => [stripModelPrefix(m.id), m]));

  // Pick top N per role with hysteresis (N from role config)
  const results = [];
  const modelToRoles = new Map();
  for (const role of ROLE_ORDER) {
    const roleCfg = rolesConfig.roles[role];
    const n = roleCfg.modelCount || 3;
    const current = preset[role]?.model || [];
    const currentVariant = preset[role]?.variant;

    const scored = scoredByRole[role];
    const pin = roleCfg.pin || [];
    let picked;
    let forced = false;
    let pinned = false;

    if (pin.length > 0) {
      // Use pinned models if they're still eligible
      const eligiblePins = pin.filter(p => candidates.some(c => c.id === stripModelPrefix(p)));
      if (eligiblePins.length >= n) {
        picked = eligiblePins.slice(0, n);
        pinned = true;
      } else if (eligiblePins.length > 0) {
        // Pin available models, pick best others to fill remaining slots
        const others = scored.filter(s => !eligiblePins.includes(s.model.id)).slice(0, n - eligiblePins.length);
        picked = [...eligiblePins, ...others.map(o => o.model.id)].filter(Boolean);
        pinned = true;
      } else {
        // Pins not available — fall through to normal picking
        forced = true;
      }
    }

    if (!picked) {
      const currentStripped = current.map(stripModelPrefix);
      const missing = currentStripped.some((m, i) => m && !candidates.some(c => c.id === m));
      if (missing) forced = true;
      picked = pickTopN(candidates, scored, currentStripped, roleCfg.keepMargin || 0.15, n);
    }

    // Resolve variant for the picked models.
    const vr = resolveVariant({
      role,
      currentVariant,
      pickedIds: picked,
      candidatesById,
    });

    // Track sharing
    for (const m of picked) {
      if (!modelToRoles.has(m)) modelToRoles.set(m, []);
      modelToRoles.get(m).push(role);
    }

    results.push({
      role,
      picked,
      old: current,
      variant: vr.variant,
      removeVariant: vr.removeVariant === true,
      oldVariant: currentVariant,
      variantChanged: vr.changed,
      variantForced: vr.forced,
      variantWarning: vr.warning,
      sharesWith: modelToRoles.get(picked[0])?.filter(r => r !== role) || [],
      forced,
      pinned,
      allCandidates: candidates
    });
  }

  // Build new config (preserve everything else byte-for-byte)
  const newConfig = JSON.parse(configRaw); // preserves key order via parse/stringify
  for (const r of results) {
    newConfig.presets.opencode[r.role].model = r.picked.map(m => `opencode/${stripModelPrefix(m)}`);
    if (r.removeVariant) {
      delete newConfig.presets.opencode[r.role].variant;
    } else if (r.variantChanged && r.variant != null) {
      newConfig.presets.opencode[r.role].variant = r.variant;
    }
  }

  const newRaw = JSON.stringify(newConfig, null, 2); // NO trailing newline
  const changed = newRaw !== configRaw;

  // Report
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

export {
  stripModelPrefix,
  normalizeVariant,
  supportedVariants,
  commonVariants,
  resolveVariant,
  pickTopN,
  scoreModel,
  filterModels,
  formatDiff,
  formatVariantDiff,
  buildReport,
  ROLE_VARIANT_PRIORITY,
  VARIANT_NEAREST,
  DEFAULT_REASONING_VARIANTS,
};

const invokedAsScript =
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (invokedAsScript) {
  main().catch(e => {
    error(e.message);
    process.exit(1);
  });
}
