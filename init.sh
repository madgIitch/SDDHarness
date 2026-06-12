#!/usr/bin/env bash
# init.sh — Bootstrap del SDD Harness (agnóstico de repo y de agente).
# Crea .harness/ + capa de memoria (docs/ spec/ progress/), detecta el stack,
# escribe gates.config.json, deja punteros en CLAUDE.md/AGENTS.md, parchea
# .gitignore y verifica el CLI del agente.
#
# Uso:
#   bash init.sh            # instala (no clobbera spec.json, memoria ni punteros)
#   bash init.sh --force    # reescribe también los scripts de .harness/
#
# Requisitos: bash, git, node. Elige agente con HARNESS_AGENT=claude|codex (def. claude).

set -euo pipefail

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

AGENT="${HARNESS_AGENT:-claude}"
say()  { printf '  %s\n' "$1"; }
step() { printf '\n== %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1" >&2; }
die()  { printf '\n❌ %s\n' "$1" >&2; exit 1; }

write() {  # write <path>  (lee el cuerpo de stdin; salta .harness/* si ya existe y no hay --force)
  local path="$1"
  if [ -e "$path" ] && [ "$FORCE" -ne 1 ]; then
    case "$path" in
      .harness/*) say "salto $path (usa --force para reescribir)"; cat >/dev/null; return;;
    esac
  fi
  cat > "$path"
  say "escrito $path"
}

seed() {  # seed <path>  (crea solo si falta; nunca clobbera la memoria)
  local path="$1"
  if [ -e "$path" ]; then say "salto $path (ya existe)"; cat >/dev/null; return; fi
  cat > "$path"; say "creado $path"
}

step "Comprobaciones previas"
command -v git  >/dev/null 2>&1 || die "git no está en el PATH."
command -v node >/dev/null 2>&1 || die "node no está en el PATH."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "esto no es un repo git. Corre 'git init' primero."
if [ "$AGENT" = "claude" ]; then
  command -v claude >/dev/null 2>&1 || warn "HARNESS_AGENT=claude pero 'claude' no está en el PATH."
elif [ "$AGENT" = "codex" ]; then
  command -v codex >/dev/null 2>&1 || warn "HARNESS_AGENT=codex pero 'codex' no está en el PATH."
else
  die "HARNESS_AGENT debe ser 'claude' o 'codex' (es '$AGENT')."
fi
say "agente seleccionado: $AGENT"

step "Creando .harness/"
mkdir -p .harness/interviews

# ---------------------------------------------------------------- runner.mjs
write .harness/runner.mjs <<'RUNNER_EOF'
import { execSync } from "node:child_process";

const AGENT = (process.env.HARNESS_AGENT || "claude").toLowerCase(); // "claude" | "codex"
const UNATTENDED = process.env.HARNESS_UNATTENDED === "1";

const q = (s) => JSON.stringify(s); // comillas seguras para el shell
const sh = (cmd) =>
  execSync(cmd, { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });

export function runAgent(prompt, { write = false } = {}) {
  return AGENT === "codex" ? runCodex(prompt, write) : runClaude(prompt, write);
}

function runClaude(prompt, write) {
  const tools = write ? "Edit,Write,Bash,Read,Grep,Glob" : "Read,Grep,Glob";
  const flags = [
    "--output-format json",
    `--max-turns ${write ? 30 : 8}`,
    `--allowedTools "${tools}"`,
    write && UNATTENDED ? "--dangerously-skip-permissions" : "",
  ].filter(Boolean).join(" ");
  const j = JSON.parse(sh(`claude -p ${q(prompt)} ${flags}`));
  return { text: j.result ?? "", cost: j.total_cost_usd ?? j.cost?.total_cost ?? null };
}

function runCodex(prompt, write) {
  const sandbox = write ? "workspace-write" : "read-only";
  const approval = UNATTENDED || write ? "--approval-policy never" : "";
  const text = sh(`codex exec ${approval} -s ${sandbox} ${q(prompt)}`);
  return { text: text.trim(), cost: null };
}

export function extractJson(text) {
  const clean = text.replace(/```json|```/g, "").trim();
  const a = clean.indexOf("{"), b = clean.lastIndexOf("}");
  if (a === -1 || b === -1) throw new Error("El agente no devolvió JSON:\n" + text.slice(0, 500));
  return JSON.parse(clean.slice(a, b + 1));
}
RUNNER_EOF

# ------------------------------------------------------------------ spec.mjs
write .harness/spec.mjs <<'SPEC_EOF'
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { runAgent, extractJson } from "./runner.mjs";

const SPEC = "spec.json";
const IDIR = ".harness/interviews";
const SPECDIR = "spec";

const DIMENSIONS = [
  "data_model", "error_states", "edge_cases", "auth_secrets",
  "external_contracts", "ui_states", "rollback_compat", "tests",
];

const sh = (cmd) => execSync(cmd, { stdio: "pipe", encoding: "utf8" });
const tryCommit = (paths, msg) => { try { sh(`git add ${paths}`); sh(`git commit -q -m ${JSON.stringify(msg)} -- ${paths}`); } catch {} };
const loadSpec = () => JSON.parse(readFileSync(SPEC, "utf8"));
const saveSpec = (s) => writeFileSync(SPEC, JSON.stringify(s, null, 2));
const scPath = (id) => `${IDIR}/${id}.json`;
const loadSc = (id) => JSON.parse(readFileSync(scPath(id), "utf8"));
const saveSc = (id, d) => { mkdirSync(IDIR, { recursive: true }); writeFileSync(scPath(id), JSON.stringify(d, null, 2)); };
const ask = (prompt) => extractJson(runAgent(prompt, { write: false }).text);

function feature(spec, id) {
  const f = spec.features.find((x) => String(x.id) === String(id));
  if (!f) throw new Error(`Feature ${id} no existe`);
  return f;
}

// Escribe el spec aprobado y destilado a spec/<id>-<name>.md (memoria durable).
function writeSpecDoc(f, sc) {
  mkdirSync(SPECDIR, { recursive: true });
  const L = [`# ${f.id} · ${f.title}`, ""];
  L.push(`- **name:** \`${f.name}\``, `- **priority:** ${f.priority ?? "-"}`, `- **sdd:** ${f.sdd === false ? "false" : "true"}`);
  L.push(`- **aprobado por:** ${f.approved_by} · ${f.approved_at}`);
  if (f.scope?.length) L.push(`- **scope:** ${f.scope.map((s) => `\`${s}\``).join(", ")}`);
  L.push("", "## Descripción", "", f.description ?? "");
  if (f.acceptance?.length) { L.push("", "## Criterios de aceptación", ""); f.acceptance.forEach((a, i) => L.push(`${i + 1}. ${a}`)); }
  if (sc?.dimensions) { L.push("", "## Cobertura por dimensión", ""); for (const [d, v] of Object.entries(sc.dimensions)) L.push(`- **${d}:** ${v.notes ?? (v.addressed ? "ok" : "—")}`); }
  if (sc?.answers && Object.keys(sc.answers).length) { L.push("", "## Decisiones de la entrevista", ""); for (const [k, v] of Object.entries(sc.answers)) L.push(`- **${k}:** ${v}`); }
  const path = `${SPECDIR}/${f.id}-${f.name}.md`;
  writeFileSync(path, L.join("\n") + "\n");
  return path;
}

function interview(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.sdd === false) { console.log(`Feature ${id} es sdd:false → sin entrevista. Apruébala: spec.mjs approve ${id}`); return; }
  const prior = existsSync(scPath(id)) ? loadSc(id) : { answers: {} };
  const res = ask([
    "Eres entrevistador de especificaciones (SDD). NO escribas código. Devuelve SOLO JSON.",
    "Analiza el repo (solo lectura), lee docs/ si existe, y esta feature:",
    JSON.stringify({ id: f.id, name: f.name, title: f.title, description: f.description, acceptance: f.acceptance ?? [] }),
    `Respuestas previas del dev: ${JSON.stringify(prior.answers)}`,
    `Para CADA dimensión [${DIMENSIONS.join(", ")}] decide si la feature la deja resuelta.`,
    'Si NO, genera una pregunta concreta de alto valor (NADA de relleno tipo "¿qué color?").',
    'Propón "scope" (paths que puede tocar) y un "acceptance" refinado y testable.',
    'Formato EXACTO: {"dimensions":{"<dim>":{"addressed":bool,"notes":"...","question":"...si addressed=false"}},"scope":[],"acceptance":[],"ready":false}',
  ].join("\n"));
  const sc = { ...prior, ...res, answers: prior.answers ?? {} };
  sc.ready = DIMENSIONS.every((d) => sc.dimensions?.[d]?.addressed === true);
  saveSc(id, sc);
  const open = DIMENSIONS.filter((d) => !sc.dimensions?.[d]?.addressed);
  if (open.length === 0) console.log(`Spec ${id}: dimensiones cubiertas. Corre: spec.mjs answer ${id}`);
  else { console.log(`PREGUNTAS ABIERTAS (feature ${id}):`); open.forEach((d) => console.log(`  [${d}] ${sc.dimensions[d].question}`)); console.log(`\nResponde en "answers" de ${scPath(id)} y corre: spec.mjs answer ${id}`); }
}

function answer(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  const sc = loadSc(id);
  const revised = ask([
    "Revisa esta spec integrando las respuestas del dev. NO escribas código. Devuelve SOLO JSON (mismo formato).",
    `Feature: ${JSON.stringify({ id: f.id, title: f.title, description: f.description })}`,
    `Borrador: ${JSON.stringify({ dimensions: sc.dimensions, scope: sc.scope, acceptance: sc.acceptance })}`,
    `Respuestas del dev: ${JSON.stringify(sc.answers)}`,
  ].join("\n"));
  const adv = ask([
    "Eres implementador. Solo con esta spec, lista en JSON cada punto donde tendrías que ADIVINAR.",
    `Spec: ${JSON.stringify({ scope: revised.scope, acceptance: revised.acceptance })}`,
    'Formato: {"guesses":[]} (vacío si no hay ninguno).',
  ].join("\n"));
  const covered = DIMENSIONS.every((d) => revised.dimensions?.[d]?.addressed === true);
  const ready = covered && (adv.guesses?.length ?? 0) === 0;
  saveSc(id, { ...sc, ...revised, adversarial: adv.guesses ?? [], ready });
  if (!ready) {
    console.log(`Feature ${id} aún NO está lista.`);
    if (!covered) console.log(`  Sin cubrir: ${DIMENSIONS.filter((d) => !revised.dimensions?.[d]?.addressed).join(", ")}`);
    (adv.guesses ?? []).forEach((g) => console.log(`  El implementador adivinaría: ${g}`));
    return;
  }
  f.acceptance = revised.acceptance; f.scope = revised.scope; f.status = "spec_ready";
  saveSpec(spec);
  console.log(`Feature ${id} → spec_ready. Revísala y aprueba: spec.mjs approve ${id}`);
}

function approve(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  const by = process.env.USER || process.env.USERNAME || "dev";
  let sc = null;
  if (f.sdd !== false) {
    sc = loadSc(id);
    if (!sc.ready) throw new Error(`Feature ${id}: spec no listo (ready:false).`);
    if (f.status !== "spec_ready") throw new Error(`Feature ${id} debe estar en spec_ready (está en ${f.status}).`);
    f.answers_hash = "sha256:" + createHash("sha256").update(JSON.stringify(sc.answers)).digest("hex");
  }
  f.spec_approved = true; f.approved_by = by; f.approved_at = new Date().toISOString();
  saveSpec(spec);
  const doc = writeSpecDoc(f, sc);
  tryCommit(`spec.json ${doc}`, `spec: approve #${f.id} ${f.name}`);
  console.log(`Feature ${id} aprobada por ${by}. Spec durable en ${doc}`);
}

function done(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.status !== "review_pending") throw new Error(`Feature ${id} no está en review_pending (está en ${f.status}).`);
  if (f.sdd !== false) sh(`git merge --no-ff harness/${f.name}`);
  f.status = "done"; saveSpec(spec);
  console.log(`Feature ${id} → done.`);
}

const [cmd, id] = process.argv.slice(2);
const cmds = { interview, answer, approve, done };
if (!cmds[cmd] || !id) { console.log("Uso: node .harness/spec.mjs <interview|answer|approve|done> <id>"); process.exit(1); }
cmds[cmd](id);
SPEC_EOF

# ---------------------------------------------------------- orchestrator.mjs
write .harness/orchestrator.mjs <<'ORCH_EOF'
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { loadSpec, loadState, saveState } from "./state.mjs";
import { runGates } from "./gates.mjs";
import { buildInitialPrompt, buildRetryPrompt } from "./prompt.mjs";
import { runAgent } from "./runner.mjs";

const DRY = process.argv.includes("--dry-run");
const PRI = { P0: 0, P1: 1, P2: 2, P3: 3 };
const PDIR = "progress";
const sh = (cmd) => execSync(cmd, { stdio: "pipe", encoding: "utf8" });

function approvalStale(f) {
  if (f.sdd === false || !f.answers_hash) return false;
  try {
    const sc = JSON.parse(readFileSync(`.harness/interviews/${f.id}.json`, "utf8"));
    const h = "sha256:" + createHash("sha256").update(JSON.stringify(sc.answers)).digest("hex");
    return h !== f.answers_hash;
  } catch { return false; }
}
function consumable(f) {
  if (f.spec_approved !== true) return false;
  if (approvalStale(f)) return false;
  return f.status === "pending" || f.status === "spec_ready";
}

// Memoria de ejecución: progress/<id>-<name>.md + LOG.md rodante.
function writeProgress(task, state) {
  mkdirSync(PDIR, { recursive: true });
  const path = `${PDIR}/${task.id}-${task.name}.md`;
  const prior = existsSync(path) ? readFileSync(path, "utf8") : `# ${task.id} · ${task.title}\n\nRegistro de implementación (memoria del proyecto).\n`;
  const attempts = state.tasks[task.id]?.attempts ?? [];
  const ts = new Date().toISOString();
  const rows = attempts.map((a) => {
    const fg = a.verdict?.passed ? "—" : (String(a.verdict?.failureOutput || "").match(/Gate fallido: ([^\n]+)/)?.[1] ?? "?");
    return `| ${a.attempt} | ${a.verdict?.passed ? "OK" : "FALLO"} | ${fg} | ${a.tts != null ? a.tts.toFixed(1) : "?"} | ${a.cost ?? "—"} |`;
  }).join("\n");
  const block = `\n## ${ts} — estado: ${task.status}\n\n- agente: ${process.env.HARNESS_AGENT || "claude"} · branch: \`harness/${task.name}\`\n\n| intento | resultado | gate fallido | tts(s) | coste |\n|--:|--|--|--:|--:|\n${rows}\n`;
  writeFileSync(path, prior + block);
  const logPath = `${PDIR}/LOG.md`;
  const log = existsSync(logPath) ? readFileSync(logPath, "utf8") : "# Changelog del harness\n\n";
  writeFileSync(logPath, log + `- ${ts} · #${task.id} ${task.name} → ${task.status} (${attempts.length} intento/s)\n`);
  try { sh(`git add ${PDIR}`); sh(`git commit -q -m "docs(progress): #${task.id} ${task.name} → ${task.status}" -- ${PDIR}`); } catch {}
}

async function main() {
  const spec = loadSpec();
  const state = loadState();
  const maxAttempts = spec.rules?.max_attempts ?? 3;
  const queue = spec.features.filter(consumable).sort((a, b) => (PRI[a.priority] ?? 9) - (PRI[b.priority] ?? 9));

  if (DRY) {
    console.log(`Cola (aprobadas y pendientes): ${queue.length}`);
    queue.forEach((f) => console.log(`  - [${f.priority}] ${f.id} ${f.name}${f.sdd ? "" : " (sdd:false)"}`));
    const waiting = spec.features.filter((f) => f.sdd && f.status === "spec_ready" && !f.spec_approved);
    if (waiting.length) console.log(`Esperando aprobación: ${waiting.map((f) => f.id).join(", ")}`);
    return;
  }

  for (const task of queue) {
    const branch = `harness/${task.name}`;
    let lastFailure = null, ok = false;
    task.status = "in_progress";
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const t0 = Date.now();
      sh(`git checkout -b ${branch} 2>/dev/null || git checkout ${branch}`);
      const prompt = lastFailure ? buildRetryPrompt(task, lastFailure, attempt) : buildInitialPrompt(task);
      const run = runAgent(prompt, { write: true });
      const verdict = await runGates(task);
      record(state, task.id, { attempt, verdict, tts: (Date.now() - t0) / 1000, cost: run.cost });
      if (verdict.passed) {
        sh(`git add -A && git commit -m "feat(${task.name}): ${task.title}"`);
        if (task.sdd === false) { sh(`git checkout - && git merge --no-ff ${branch}`); task.status = "done"; }
        else { sh("git checkout -"); task.status = "review_pending"; console.log(`Feature ${task.id} en ${branch} → review_pending. Cierra con: spec.mjs done ${task.id}`); }
        ok = true; break;
      }
      lastFailure = verdict.failureOutput;
      sh(`git checkout - && git branch -D ${branch}`);
    }
    if (!ok) { task.status = "blocked"; console.error(`⚠️  BLOCKED: ${task.id} ${task.name} falló ${maxAttempts} veces.`); console.error(state.tasks[task.id]?.attempts.at(-1)?.verdict?.failureOutput ?? ""); }
    saveState(state);
    writeFileSync("spec.json", JSON.stringify(spec, null, 2));
    writeProgress(task, state);
  }
}

function record(state, id, entry) { state.tasks[id] ??= { attempts: [] }; state.tasks[id].attempts.push(entry); }
main().catch((e) => { console.error("Harness error:", e); process.exit(1); });
ORCH_EOF

# ------------------------------------------------------------------ gates.mjs
write .harness/gates.mjs <<'GATES_EOF'
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const cfg = JSON.parse(readFileSync(new URL("./gates.config.json", import.meta.url)));
const ALWAYS = ["docs/", "spec/", "progress/"]; // memoria: siempre permitida fuera del scope

function run(cmd) {
  try { return { ok: true, out: execSync(cmd, { stdio: "pipe", encoding: "utf8" }) }; }
  catch (e) { return { ok: false, out: (e.stdout ?? "") + (e.stderr ?? "") }; }
}
function diffScopeGate(task) {
  const changed = execSync("git diff --name-only HEAD", { encoding: "utf8" }).split("\n").filter(Boolean);
  const declared = task.scope ?? [];
  if (declared.length === 0) return { ok: true, out: "" };
  const allowed = [...declared, ...ALWAYS];
  const outside = changed.filter((f) => !allowed.some((p) => f.startsWith(p)));
  return outside.length === 0 ? { ok: true, out: "" } : { ok: false, out: `Archivos fuera de scope: ${outside.join(", ")}` };
}
export async function runGates(task) {
  const failures = [];
  for (const gate of cfg.gates) {
    let res = gate.name === "diff-scope" ? diffScopeGate(task) : run(gate.cmd);
    if (res.ok && gate.maxWarnings != null) {
      const n = (res.out.match(new RegExp(gate.warningPattern, "g")) ?? []).length;
      if (n > gate.maxWarnings) res = { ok: false, out: `${n} warnings (máx ${gate.maxWarnings})\n${res.out}` };
    }
    if (!res.ok) { failures.push(`### Gate fallido: ${gate.name}\n${res.out.slice(0, 4000)}`); if (gate.blocking !== false) break; }
  }
  return { passed: failures.length === 0, failureOutput: failures.join("\n\n") };
}
GATES_EOF

# ------------------------------------------------------------------ state.mjs
write .harness/state.mjs <<'STATE_EOF'
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const STATE = ".harness/harness-state.json";
export const loadSpec = () => JSON.parse(readFileSync("spec.json", "utf8"));
export const loadState = () => existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : { tasks: {}, startedAt: new Date().toISOString() };
export const saveState = (s) => writeFileSync(STATE, JSON.stringify(s, null, 2));
STATE_EOF

# ----------------------------------------------------------------- prompt.mjs
write .harness/prompt.mjs <<'PROMPT_EOF'
export function buildInitialPrompt(task) {
  return [
    "Implementa esta feature (metodología SDD). El spec ya fue aprobado por el dev.",
    "Antes de empezar, lee docs/ARCHITECTURE.md, docs/CONVENTIONS.md y docs/DECISIONS.md si existen, y respétalos.",
    `id: ${task.id}  name: ${task.name}`,
    `Título: ${task.title}`,
    `Descripción: ${task.description}`,
    task.scope?.length ? `SOLO puedes tocar: ${task.scope.join(", ")} (además de docs/ para registrar decisiones).` : "",
    "Criterios de aceptación:",
    ...(task.acceptance ?? []).map((a, i) => `  ${i + 1}. ${a}`),
    "Si tomas una decisión de arquitectura relevante, añádela como entrada nueva en docs/DECISIONS.md.",
    "Reglas: no hagas commits (lo hace el harness), no salgas del scope. Los gates verificarán tu trabajo.",
  ].filter(Boolean).join("\n");
}
export function buildRetryPrompt(task, failure, attempt) {
  return [
    buildInitialPrompt(task),
    `\n--- INTENTO ${attempt}: el anterior FALLÓ la verificación ---`,
    "Salida exacta de los gates. Corrige solo eso, no reescribas todo:",
    failure,
  ].join("\n");
}
PROMPT_EOF

step "Detectando stack → gates.config.json"
STACK="desconocido"
if [ -f tsconfig.json ] || [ -f package.json ]; then
  STACK="node/ts"
  TEST_CMD="npm test --silent"
  grep -q '"jest"'   package.json 2>/dev/null && TEST_CMD="npx jest --silent" || true
  grep -q '"vitest"' package.json 2>/dev/null && TEST_CMD="npx vitest run"   || true
  write .harness/gates.config.json <<EOF
{
  "gates": [
    { "name": "typecheck", "cmd": "npx tsc --noEmit", "blocking": true },
    { "name": "lint", "cmd": "npx eslint . --format unix", "maxWarnings": 0, "warningPattern": "warning", "blocking": true },
    { "name": "test", "cmd": "$TEST_CMD", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
EOF
elif [ -d supabase/functions ]; then
  STACK="supabase/deno"
  write .harness/gates.config.json <<'EOF'
{
  "gates": [
    { "name": "deno-check", "cmd": "deno check supabase/functions/**/*.ts", "blocking": true },
    { "name": "lint", "cmd": "deno lint", "blocking": true },
    { "name": "test", "cmd": "deno test -A", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
EOF
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  STACK="python"
  write .harness/gates.config.json <<'EOF'
{
  "gates": [
    { "name": "lint", "cmd": "ruff check .", "blocking": true },
    { "name": "types", "cmd": "mypy .", "blocking": false },
    { "name": "test", "cmd": "pytest -q", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
EOF
elif [ -f go.mod ]; then
  STACK="go"
  write .harness/gates.config.json <<'EOF'
{
  "gates": [
    { "name": "vet", "cmd": "go vet ./...", "blocking": true },
    { "name": "build", "cmd": "go build ./...", "blocking": true },
    { "name": "test", "cmd": "go test ./...", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
EOF
elif [ -f Cargo.toml ]; then
  STACK="rust"
  write .harness/gates.config.json <<'EOF'
{
  "gates": [
    { "name": "clippy", "cmd": "cargo clippy -- -D warnings", "blocking": true },
    { "name": "build", "cmd": "cargo build", "blocking": true },
    { "name": "test", "cmd": "cargo test", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
EOF
else
  write .harness/gates.config.json <<'EOF'
{
  "gates": [
    { "name": "test", "cmd": "echo 'TODO: define un comando de tests' && false", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
EOF
  warn "Stack no detectado: edita .harness/gates.config.json a mano."
fi
say "stack: $STACK"

step "spec.json"
if [ -e spec.json ] && [ "$FORCE" -ne 1 ]; then
  say "salto spec.json (ya existe)"
else
  write spec.json <<'EOF'
{
  "project": "REPLACE_ME",
  "description": "",
  "rules": {
    "one_feature_at_a_time": true,
    "require_tests_to_close": true,
    "require_approved_spec_to_implement": true,
    "valid_status": ["pending", "spec_ready", "in_progress", "review_pending", "done", "blocked"],
    "sdd_required_when": "feature tiene \"sdd\": true",
    "max_attempts": 3
  },
  "features": []
}
EOF
fi

step "Memoria del proyecto (docs/ spec/ progress/)"
mkdir -p docs spec progress

seed docs/README.md <<'EOF'
# docs/ — Memoria durable del proyecto

- `ARCHITECTURE.md` — visión general, componentes, flujo de datos.
- `DECISIONS.md` — registro de decisiones (ADR). El harness añade entradas al tomar decisiones relevantes.
- `CONVENTIONS.md` — convenciones de código, naming, ramas.

El agente lee esta carpeta antes de implementar. Mantenla actualizada: es lo que un agente nuevo
(o tú dentro de tres meses) usa para ponerse al día.
EOF

seed docs/ARCHITECTURE.md <<'EOF'
# Arquitectura

> Rellena esto. El agente lo lee antes de implementar.

## Visión general

## Componentes

## Flujo de datos

## Decisiones abiertas
EOF

seed docs/DECISIONS.md <<'EOF'
# Decisiones (ADR)

Formato por entrada: **fecha · título** — contexto, decisión y consecuencias.
El harness añade entradas cuando un agente toma una decisión de arquitectura relevante.

<!-- Nuevas entradas debajo -->
EOF

seed docs/CONVENTIONS.md <<'EOF'
# Convenciones

- Metodología: SDD (una feature a la vez, spec aprobado antes de implementar).
- Ramas: `harness/<feature-name>`.
- Commits de feature: `feat(<name>): <título>`.
- Tests obligatorios para cerrar una feature.

## Estilo de código

(añade aquí lo específico del repo)
EOF

seed spec/README.md <<'EOF'
# spec/ — Specs aprobados (durables, versionados)

`spec.json` (raíz) es la cola viva. Aquí queda el spec **destilado y aprobado** de cada feature,
un archivo por feature (`<id>-<name>.md`), generado por `spec.mjs approve`. Es la versión legible
y trazable: qué se acordó, con qué criterios y por qué.
EOF

seed progress/README.md <<'EOF'
# progress/ — Memoria de ejecución

Un archivo por feature (`<id>-<name>.md`) con el registro de cada corrida: intentos, gate que falló,
tiempo y coste. `LOG.md` es el changelog rodante. Lo genera el orquestador automáticamente.

(`.harness/harness-state.json` es el log crudo por máquina y NO se versiona; esto es el resumen curado que sí.)
EOF

seed progress/LOG.md <<'EOF'
# Changelog del harness

EOF

step "Punteros CLAUDE.md / AGENTS.md"
POINTER=$'# Instrucciones del repo\n\nAntes de actuar, lee `HARNESS.md` y síguelo.\nSi falta el directorio `.harness/`, instálalo siguiendo la sección 4 de `HARNESS.md`.\nLee `docs/` para el contexto del proyecto antes de implementar.\nNunca implementes una feature cuyo spec no esté aprobado (`spec_approved: true`).\n'
for f in CLAUDE.md AGENTS.md; do
  if [ ! -e "$f" ]; then printf '%s' "$POINTER" > "$f"; say "creado $f";
  elif ! grep -q "HARNESS.md" "$f"; then printf '\n%s' "$POINTER" >> "$f"; say "puntero añadido a $f";
  else say "salto $f (ya apunta a HARNESS.md)"; fi
done

step ".gitignore"
touch .gitignore
# docs/ spec/ progress/ se versionan (son la memoria); solo lo efímero se ignora.
for line in ".harness/harness-state.json" ".harness/interviews/"; do
  grep -qxF "$line" .gitignore || { printf '%s\n' "$line" >> .gitignore; say "añadido: $line"; }
done

step "Dry-run"
if node .harness/orchestrator.mjs --dry-run; then :; else warn "El dry-run falló (revisa spec.json)."; fi

cat <<'DONE'

✅ Harness + memoria instalados. Próximos pasos:

   export HARNESS_AGENT=claude        # o codex
   # rellena docs/ARCHITECTURE.md y docs/CONVENTIONS.md con el contexto del repo
   node .harness/spec.mjs interview 1 # solo features sdd:true
   node .harness/spec.mjs answer 1
   node .harness/spec.mjs approve 1   # → escribe spec/<id>-<name>.md
   node .harness/orchestrator.mjs     # → escribe progress/<id>-<name>.md + LOG.md

   ⚠️ Córrelo en una branch/worktree aislada (HARNESS_UNATTENDED=1 da escritura sin confirmación).
DONE