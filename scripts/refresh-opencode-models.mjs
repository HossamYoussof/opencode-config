#!/usr/bin/env node
/**
 * refresh-opencode-models.mjs
 *
 * Picks the best-fit free opencode models for each agent role in the
 * `opencode` preset of oh-my-opencode-slim.json using deterministic scoring.
 *
 * Usage:
 *   node scripts/refresh-opencode-models.mjs [options]
 *
 * Options:
 *   --config <path>        Path to oh-my-opencode-slim.json (default: oh-my-opencode-slim.json)
 *   --roles <path>         Path to opencode-model-roles.json (default: scripts/opencode-model-roles.json)
 *   --report <path>        Write markdown change report to this file
 *   --dry-run              Do not write config; print what would change
 *   --check                Exit 1 if changes would be made, 0 if no changes (for CI)
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
    const diff = formatDiff(old, r.picked);
    if (diff !== '  (unchanged)') any = true;
    lines.push(`### ${role}`);
    lines.push(diff);
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
    lines.push('*No changes — all roles already optimal*');
    lines.push('');
  }
  lines.push('## Candidate Pool');
  lines.push('');
  lines.push('| Model | Context | Output | Attachment | Reasoning | Release |');
  lines.push('|-------|--------:|-------:|:----------:|:---------:|--------|');
  for (const m of results[0].allCandidates) {
    lines.push(`| ${m.id} | ${m.limit.context.toLocaleString()} | ${m.limit.output.toLocaleString()} | ${m.attachment ? '✅' : '❌'} | ${m.reasoning ? '✅' : '❌'} | ${m.release_date || 'unknown'} |`);
  }
  return lines.join('\n');
}

async function main() {
  const opts = parseArgs();
  if (opts.help) {
    console.log(`
Usage: node scripts/refresh-opencode-models.mjs [options]

Options:
  --config <path>     Path to oh-my-opencode-slim.json (default: ${DEFAULT_CONFIG})
  --roles <path>      Path to opencode-model-roles.json (default: ${DEFAULT_ROLES})
  --report <path>     Write markdown report to file
  --dry-run           Do not write config; print what would change
  --check             Exit 1 if changes would be made, 0 if no changes
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

  // Pick top N per role with hysteresis (N from role config)
  const results = [];
  const modelToRoles = new Map();
  for (const role of ROLE_ORDER) {
    const roleCfg = rolesConfig.roles[role];
    const n = roleCfg.modelCount || 3;
    const current = preset[role]?.model || [];

    const scored = scoredByRole[role];
    const pin = roleCfg.pin || [];
    let picked;
    let forced = false;
    let pinned = false;

    if (pin.length > 0) {
      // Use pinned models if they're still eligible
      const eligiblePins = pin.filter(p => candidates.some(c => c.id === stripPrefix(p)));
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

    function stripPrefix(id) {
      return id.startsWith('opencode/') ? id.slice('opencode/'.length) : id;
    }

    if (!picked) {
      const currentStripped = current.map(stripPrefix);
      const missing = currentStripped.some((m, i) => m && !candidates.some(c => c.id === m));
      if (missing) forced = true;
      picked = pickTopN(candidates, scored, currentStripped, roleCfg.keepMargin || 0.15, n);
    }

    // Track sharing
    for (const m of picked) {
      if (!modelToRoles.has(m)) modelToRoles.set(m, []);
      modelToRoles.get(m).push(role);
    }

    results.push({
      role,
      picked,
      old: current,
      sharesWith: modelToRoles.get(picked[0])?.filter(r => r !== role) || [],
      forced,
      pinned,
      allCandidates: candidates
    });
  }

  // Build new config (preserve everything else byte-for-byte)
  const newConfig = JSON.parse(configRaw); // preserves key order via parse/stringify
  for (const r of results) {
    newConfig.presets.opencode[r.role].model = r.picked.map(m => `opencode/${m}`);
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

main().catch(e => {
  error(e.message);
  process.exit(1);
});