#!/usr/bin/env bash
# init.sh — Bootstrap del SDD Harness (agnóstico de repo y de agente).
# Crea .harness/ + memoria (docs/ spec/ progress/), detecta el stack, escribe
# gates.config.json, deja punteros en CLAUDE.md/AGENTS.md, parchea .gitignore.
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

write() {  # write <path>  (salta .harness/* si ya existe y no hay --force)
  local path="$1"
  if [ -e "$path" ] && [ "$FORCE" -ne 1 ]; then
    case "$path" in
      .harness/*) say "salto $path (usa --force para reescribir)"; cat >/dev/null; return;;
    esac
  fi
  cat > "$path"; say "escrito $path"
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
if [ "$AGENT" = "claude" ]; then command -v claude >/dev/null 2>&1 || warn "HARNESS_AGENT=claude pero 'claude' no está en el PATH.";
elif [ "$AGENT" = "codex" ]; then command -v codex >/dev/null 2>&1 || warn "HARNESS_AGENT=codex pero 'codex' no está en el PATH.";
else die "HARNESS_AGENT debe ser 'claude' o 'codex' (es '$AGENT')."; fi
say "agente seleccionado: $AGENT"

step "Creando .harness/"
mkdir -p .harness/interviews

# ---------------------------------------------------------------- runner.mjs
write .harness/runner.mjs <<'RUNNER_EOF'
import { spawnSync } from "node:child_process";

const AGENT = (process.env.HARNESS_AGENT || "claude").toLowerCase(); // "claude" | "codex"
const UNATTENDED = process.env.HARNESS_UNATTENDED === "1";
const IS_WIN = process.platform === "win32";
const TIMEOUT = Number(process.env.HARNESS_TIMEOUT_MS || 900000); // 15 min por corrida

const bin = (name) => process.env[`HARNESS_${name.toUpperCase()}_BIN`] || name;

// Lanza el CLI pasando el PROMPT POR STDIN (input), no como argumento:
//  - evita problemas de comillas/saltos de línea (sobre todo en Windows/cmd.exe);
//  - al cerrar stdin se entrega EOF, lo que evita el cuelgue conocido de `codex exec`
//    cuando lo invoca un proceso hijo no interactivo.
// shell:true en Windows resuelve los shims .cmd/.exe (cmd.exe usa PATHEXT).
function exec(name, args, prompt) {
  const cmd = bin(name);
  const res = spawnSync(cmd, args, {
    input: prompt, encoding: "utf8", shell: IS_WIN, timeout: TIMEOUT,
    maxBuffer: 64 * 1024 * 1024, stdio: ["pipe", "pipe", "inherit"],
  });
  if (res.error) {
    const U = name.toUpperCase();
    throw new Error(`No se pudo lanzar '${cmd}'. ¿Está en el PATH? Fija la ruta con HARNESS_${U}_BIN ` +
      `(p.ej. PowerShell: $env:HARNESS_${U}_BIN='C:\\ruta\\${cmd}.exe').\nDetalle: ${res.error.message}`);
  }
  if (res.status !== 0) throw new Error(`'${cmd}' salió con código ${res.status}:\n${res.stdout || ""}`);
  return res.stdout || "";
}

export function runAgent(prompt, { write = false } = {}) {
  return AGENT === "codex" ? runCodex(prompt, write) : runClaude(prompt, write);
}
function runClaude(prompt, write) {
  const tools = write ? "Edit,Write,Bash,Read,Grep,Glob" : "Read,Grep,Glob";
  const args = ["-p", "--output-format", "json", "--max-turns", String(write ? 30 : 8), "--allowedTools", tools];
  if (write && UNATTENDED) args.push("--dangerously-skip-permissions");
  const j = JSON.parse(exec("claude", args, prompt));
  return { text: j.result ?? "", cost: j.total_cost_usd ?? j.cost?.total_cost ?? null };
}
function runCodex(prompt, write) {
  const sandbox = write ? "workspace-write" : "read-only";
  const args = ["exec", "-s", sandbox];
  if (UNATTENDED || write) args.push("-c", "approval_policy='never'");
  args.push("-"); // '-' = leer el prompt completo desde stdin
  return { text: exec("codex", args, prompt).trim(), cost: null };
}

export function extractJson(text) {
  const clean = text.replace(/```json|```/g, "").trim();
  const a = clean.indexOf("{"), b = clean.lastIndexOf("}");
  if (a === -1 || b === -1) throw new Error("El agente no devolvió JSON:\n" + text.slice(0, 500));
  return JSON.parse(clean.slice(a, b + 1));
}
RUNNER_EOF

# --------------------------------------------------------------- interview.mjs
write .harness/interview.mjs <<'INTERVIEW_EOF'
// Entrevistas como Markdown editable + parseable. El dev responde en líneas **R:**.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";

const IDIR = ".harness/interviews";
export const interviewPath = (f) => `${IDIR}/${f.id}-${f.name}.md`;
export const answersHash = (answers) => "sha256:" + createHash("sha256").update(JSON.stringify(answers)).digest("hex");
const stableKey = (prefix, text) => `${prefix}-${createHash("sha1").update(String(text)).digest("hex").slice(0, 10)}`;

function normalizeList(v) {
  if (Array.isArray(v)) return v.map((x) => String(x).trim()).filter(Boolean);
  if (!v) return [];
  return String(v).split(/\n/).map((s) => s.replace(/^[-*]\s*/, "").trim()).filter(Boolean);
}

// Extrae { dim/clave: respuesta } de los bloques "### [clave] ...\n**R:** ...".
export function parseAnswers(md) {
  const out = {};
  const re = /### \[([^\]]+)\][^\n]*\n+\*\*R:\*\*\s*([\s\S]*?)(?=\n### |\n## )/g;
  let m;
  while ((m = re.exec(md))) { const a = m[2].trim(); if (a) out[m[1]] = a; }
  return out;
}
// Extrae cobertura { dim: {addressed, notes} } de los bullets "- ✅/❓ dim — nota".
export function parseDimensions(md) {
  const out = {};
  const after = (md.split("## Cobertura de dimensiones")[1] || "").split("\n## ")[0];
  const re = /^- (✅|❓) (\w+)\s*—\s*(.*)$/gm;
  let m;
  while ((m = re.exec(after))) out[m[2]] = { addressed: m[1] === "✅", notes: m[3].trim() };
  return out;
}
export function readInterview(f) {
  const p = interviewPath(f);
  if (!existsSync(p)) return { answers: {}, dimensions: {} };
  const md = readFileSync(p, "utf8");
  return { answers: parseAnswers(md), dimensions: parseDimensions(md), md };
}
export function writeInterview(f, md) { mkdirSync(IDIR, { recursive: true }); writeFileSync(interviewPath(f), md); }

// Renderiza la entrevista. res = { dimensions, scope, acceptance } del agente.
export function renderInterview(f, res, priorAnswers = {}, guesses = []) {
  const dims = res.dimensions || {};
  const open = Object.keys(dims).filter((d) => !dims[d].addressed);
  const ready = open.length === 0; // readiness = SOLO cobertura de dimensiones (los guesses no bloquean)
  const title = f.title ?? f.name ?? f.id;
  const L = [`# Entrevista · ${f.id} · ${title}`, "", `- name: \`${f.name ?? title}\``];
  L.push(ready ? `- estado: **dimensiones cubiertas** → aprueba con \`spec.mjs approve ${f.id}\``
               : `- estado: responde los **R:** y corre \`spec.mjs answer ${f.id}\``, "");
  if (open.length) {
    L.push("## Preguntas abiertas", "", "> Escribe tu respuesta en la línea `**R:**` de cada bloque.", "");
    open.forEach((d) => L.push(`### [${d}] ${dims[d].question ?? "Aclara esta dimensión"}`, "", `**R:** ${priorAnswers[d] ?? ""}`, ""));
  }
  if (guesses.length) {
    L.push("## Suposiciones del implementador", "", "> No bloquean la aprobación, pero conviene revisarlas. Puedes responder en su `**R:**` para fijarlas en el diseño.", "");
    guesses.forEach((g) => {
      const key = stableKey("adv", g);
      L.push(`### [${key}] ${g}`, "", `**R:** ${priorAnswers[key] ?? ""}`, "");
    });
  }
  if (ready) {
    const recorded = Object.entries(priorAnswers).filter(([k]) => !k.startsWith("adv"));
    if (recorded.length) { L.push("## Decisiones registradas", ""); recorded.forEach(([k, v]) => L.push(`### [${k}] (resuelto)`, "", `**R:** ${v}`, "")); }
  }
  L.push("## Cobertura de dimensiones", "");
  for (const [d, v] of Object.entries(dims)) L.push(`- ${v.addressed ? "✅" : "❓"} ${d} — ${v.notes || (v.addressed ? "ok" : "pendiente")}`);
  L.push("", "## Scope propuesto", "", ...normalizeList(res.scope).map((s) => `- \`${s}\``), "");
  L.push("## Acceptance propuesto", "", ...normalizeList(res.acceptance).map((a, i) => `${i + 1}. ${a}`), "");
  return L.join("\n") + "\n";
}
INTERVIEW_EOF

# ------------------------------------------------------------------ spec.mjs
write .harness/spec.mjs <<'SPEC_EOF'
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { runAgent, extractJson } from "./runner.mjs";
import { readInterview, writeInterview, renderInterview, interviewPath, answersHash } from "./interview.mjs";

const SPEC = "spec.json";
const SPECDIR = "spec";
const DIMENSIONS = [
  "data_model", "error_states", "edge_cases", "auth_secrets",
  "external_contracts", "ui_states", "rollback_compat", "tests",
];

const sh = (cmd) => execSync(cmd, { stdio: "pipe", encoding: "utf8" });
const tryCommit = (paths, msg) => { try { sh(`git add ${paths}`); sh(`git commit -q -m ${JSON.stringify(msg)} -- ${paths}`); } catch {} };
const loadSpec = () => JSON.parse(readFileSync(SPEC, "utf8"));
const saveSpec = (s) => writeFileSync(SPEC, JSON.stringify(s, null, 2) + "\n");
const ask = (prompt) => extractJson(runAgent(prompt, { write: false }).text);

function normalizeList(v) {
  if (Array.isArray(v)) return v.map((x) => String(x).trim()).filter(Boolean);
  if (!v) return [];
  return String(v).split(/\n/).map((s) => s.replace(/^[-*]\s*/, "").trim()).filter(Boolean);
}

function parseNumberedSection(md, heading) {
  if (!md) return [];
  const section = (md.split(`## ${heading}`)[1] || "").split("\n## ")[0];
  const items = [];
  let current = null;
  for (const rawLine of section.split("\n")) {
    const line = rawLine.trim();
    if (!line) continue;
    const numbered = line.match(/^\d+\.\s+(.*)$/);
    if (numbered) {
      if (current) items.push(current.trim());
      current = numbered[1];
    } else if (current) {
      current += ` ${line}`;
    }
  }
  if (current) items.push(current.trim());
  return items;
}

function parseScopeSection(md) {
  if (!md) return [];
  const section = (md.split("## Scope propuesto")[1] || "").split("\n## ")[0];
  return section.split("\n")
    .map((l) => l.trim().match(/^-\s+`?([^`]+)`?$/)?.[1]?.trim())
    .filter(Boolean);
}

function normalizeGuesses(v) {
  const guesses = Array.isArray(v) ? v : (v ? [v] : []);
  return guesses.map((g) => {
    if (typeof g === "string") return g;
    if (g && typeof g === "object") {
      const vals = ["question", "point", "text", "reason"].map((k) => g[k]).filter((x) => typeof x === "string" && x.trim());
      return vals.length ? vals.join(" — ") : JSON.stringify(g);
    }
    return String(g);
  }).map((s) => s.replace(/\s+/g, " ").trim()).filter(Boolean);
}

// Garantiza que las 8 dimensiones existan (un dim ausente = sin cubrir, con pregunta).
function fillDims(dims = {}) {
  const out = {};
  for (const d of DIMENSIONS) out[d] = dims[d] ?? { addressed: false, question: "Aclara esta dimensión (el agente no la cubrió)." };
  return out;
}

function feature(spec, id) {
  const f = spec.features.find((x) => String(x.id) === String(id));
  if (!f) throw new Error(`Feature ${id} no existe`);
  return f;
}
function dimList(intv, dims) {
  if (!intv?.dimensions) return [];
  return dims.filter((d) => intv.dimensions[d] && (intv.dimensions[d].notes || intv.dimensions[d].addressed))
    .map((d) => `- **${d}:** ${intv.dimensions[d].notes || "ok"}`);
}

// Escribe el spec aprobado a spec/<id>-<name>/ con requirements.md, design.md y tasks.md.
function writeSpecFolder(f, intv) {
  const dir = `${SPECDIR}/${f.id}-${f.name}`;
  mkdirSync(dir, { recursive: true });
  const meta = `- name: \`${f.name}\` · priority: ${f.priority ?? "-"} · sdd: ${f.sdd === false ? "false" : "true"}\n- aprobado por: ${f.approved_by} · ${f.approved_at}`;

  const req = [`# ${f.id} · ${f.title} — Requisitos`, "", meta, "", "## Contexto", "", f.description ?? "", ""];
  if (f.acceptance?.length) { req.push("## Requisitos funcionales", ""); f.acceptance.forEach((a, i) => req.push(`R${i + 1}. ${a}`)); req.push(""); }
  const cons = dimList(intv, ["error_states", "auth_secrets", "rollback_compat"]);
  if (cons.length) req.push("## Restricciones", "", ...cons, "");
  writeFileSync(`${dir}/requirements.md`, req.join("\n") + "\n");

  const des = [`# ${f.id} · ${f.title} — Diseño`, ""];
  if (f.scope?.length) des.push("## Scope (archivos que puede tocar)", "", ...f.scope.map((s) => `- \`${s}\``), "");
  const dd = dimList(intv, ["data_model", "external_contracts", "edge_cases", "ui_states"]);
  if (dd.length) des.push("## Enfoque", "", ...dd, "");
  if (intv?.answers && Object.keys(intv.answers).length) des.push("## Decisiones de la entrevista", "", ...Object.entries(intv.answers).map(([k, v]) => `- **${k}:** ${v}`), "");
  writeFileSync(`${dir}/design.md`, des.join("\n") + "\n");

  const tk = [`# ${f.id} · ${f.title} — Tareas`, "", "Checklist de implementación. El agente marca [x] al completar; los gates verifican.", ""];
  if (f.acceptance?.length) f.acceptance.forEach((a, i) => tk.push(`- [ ] (T${i + 1}) ${a}  ↔ R${i + 1}`));
  else tk.push(`- [ ] ${f.description ?? f.title}`);
  tk.push("- [ ] Tests que cubran los criterios de aceptación");
  writeFileSync(`${dir}/tasks.md`, tk.join("\n") + "\n");
  return dir;
}

function appendOnce(path, marker, lines) {
  mkdirSync("docs", { recursive: true });
  const current = existsSync(path) ? readFileSync(path, "utf8") : "";
  if (current.includes(marker)) return;
  writeFileSync(path, `${current.trimEnd()}\n\n${lines.join("\n")}\n`);
}

// Alimenta docs/ con contexto durable al aprobar specs. Esto evita que docs/ quede
// como placeholder eterno y convierte cada aprobación en memoria reutilizable.
function writeDocsFromSpec(f, intv) {
  const marker = `<!-- harness:${f.id} -->`;
  const title = f.title ?? f.name ?? f.id;
  const scope = (f.scope ?? []).map((s) => `  - \`${s}\``);
  const approach = dimList(intv, ["data_model", "external_contracts", "edge_cases", "ui_states"]);
  appendOnce("docs/ARCHITECTURE.md", marker, [
    marker,
    `## ${f.id} · ${title}`,
    "",
    f.description ?? "",
    "",
    "### Scope aprobado",
    "",
    ...(scope.length ? scope : ["  - (sin scope declarado)"]),
    "",
    ...(approach.length ? ["### Contexto técnico", "", ...approach, ""] : []),
  ]);

  const decisions = dimList(intv, ["auth_secrets", "rollback_compat", "tests"]);
  appendOnce("docs/DECISIONS.md", marker, [
    marker,
    `## ${new Date().toISOString().slice(0, 10)} · ${f.id} aprobado`,
    "",
    `Contexto: se aprobó el spec \`${f.id}\` (${title}).`,
    "",
    ...(decisions.length ? ["Decisiones registradas:", "", ...decisions] : ["Decisión: implementar según el spec aprobado."]),
    "",
    "Consecuencia: futuras features deben respetar este contrato salvo nuevo ADR.",
  ]);
}

function interview(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.sdd === false) { console.log(`Feature ${id} es sdd:false → sin entrevista. Apruébala: spec.mjs approve ${id}`); return; }
  const prior = readInterview(f);
  const res = ask([
    "Eres entrevistador de especificaciones (SDD). NO escribas código. Lee docs/ si existe. Devuelve SOLO JSON.",
    "Feature:", JSON.stringify({ id: f.id, name: f.name, title: f.title, description: f.description, acceptance: f.acceptance ?? [] }),
    `Respuestas previas del dev: ${JSON.stringify(prior.answers)}`,
    `Para CADA dimensión [${DIMENSIONS.join(", ")}] decide si la feature la deja resuelta.`,
    'Si NO, genera una pregunta concreta de alto valor (NADA de relleno tipo "¿qué color?").',
    'Propón "scope" (paths que puede tocar) y un "acceptance" refinado y testable.',
    'Formato EXACTO: {"dimensions":{"<dim>":{"addressed":bool,"notes":"...","question":"...si addressed=false"}},"scope":[],"acceptance":[]}',
  ].join("\n"));
  res.dimensions = fillDims(res.dimensions);
  writeInterview(f, renderInterview(f, res, prior.answers, []));
  const open = DIMENSIONS.filter((d) => !res.dimensions[d].addressed);
  if (open.length === 0) console.log(`Spec ${id}: dimensiones cubiertas de salida. Corre: spec.mjs answer ${id}`);
  else { console.log(`Entrevista en ${interviewPath(f)} — preguntas abiertas:`); open.forEach((d) => console.log(`  [${d}] ${res.dimensions[d].question}`)); console.log(`Responde los **R:** y corre: spec.mjs answer ${id}`); }
}

function answer(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  const prior = readInterview(f);
  const existingAC = parseNumberedSection(prior.md, "Acceptance propuesto");
  const existingScope = parseScopeSection(prior.md);
  const revised = ask([
    "Revisa esta spec integrando las respuestas del dev. NO escribas código. Devuelve SOLO JSON (mismo formato).",
    `Feature: ${JSON.stringify({ id: f.id, title: f.title, description: f.description })}`,
    `Cobertura previa: ${JSON.stringify(prior.dimensions)}`,
    `Respuestas del dev: ${JSON.stringify(prior.answers)}`,
    existingAC.length
      ? `Criterios de aceptación existentes (presérvalos salvo que una respuesta del dev los vuelva más precisos): ${JSON.stringify(existingAC)}`
      : "",
    existingScope.length
      ? `Scope existente (presérvalo salvo contradicción explícita): ${JSON.stringify(existingScope)}`
      : "",
    `Dimensiones: [${DIMENSIONS.join(", ")}]. Mismo formato JSON con dimensions/scope/acceptance.`,
  ].filter(Boolean).join("\n"));
  revised.dimensions = fillDims(revised.dimensions);
  const finalAcceptance = existingAC.length ? existingAC : normalizeList(revised.acceptance);
  const finalScope = existingScope.length ? existingScope : normalizeList(revised.scope);
  const adv = ask([
    "Eres QA de criterios de aceptación. Lista SOLO ambigüedades bloqueantes: casos donde no se puede decidir si el sistema PASA o FALLA sin una decisión de negocio adicional.",
    "NO reportes detalles internos de implementación, testIDs, props de componentes, librerías, estructura de carpetas ni configuración de CI si no cambian el comportamiento observable.",
    "SÍ reporta umbrales indefinidos, endpoints/rutas no especificadas, campos de request/response faltantes y comportamientos observables donde dos implementaciones razonables darían resultados distintos.",
    `Spec: ${JSON.stringify({ scope: finalScope, acceptance: finalAcceptance })}`,
    'Formato: {"guesses":["string"]} (vacío si no hay ninguno).',
  ].join("\n"));
  const guesses = normalizeGuesses(adv.guesses);
  const ready = DIMENSIONS.every((d) => revised.dimensions[d].addressed === true);
  writeInterview(f, renderInterview(f, { ...revised, scope: finalScope, acceptance: finalAcceptance }, prior.answers, guesses));
  if (!ready) {
    console.log(`Feature ${id} aún NO está lista — dimensiones sin cubrir:`);
    DIMENSIONS.filter((d) => !revised.dimensions[d].addressed).forEach((d) => console.log(`  [${d}] ${revised.dimensions[d].question ?? ""}`));
    if (guesses.length) console.log(`(${guesses.length} suposición(es) del implementador anotadas en el .md)`);
    return;
  }
  f.acceptance = finalAcceptance; f.scope = finalScope; f.status = "spec_ready";
  saveSpec(spec);
  console.log(`Feature ${id} → spec_ready (dimensiones cubiertas).`);
  if (guesses.length) { console.log("⚠️  Suposiciones del implementador a revisar antes de approve:"); guesses.forEach((g) => console.log(`  - ${g}`)); }
  console.log(`Aprueba con: spec.mjs approve ${id}`);
}

function forceReady(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.sdd === false) { console.log(`Feature ${id} es sdd:false; usa approve directo.`); return; }
  const prior = readInterview(f);
  const acceptance = parseNumberedSection(prior.md, "Acceptance propuesto");
  const scope = parseScopeSection(prior.md);
  if (!acceptance.length) throw new Error(`No hay "Acceptance propuesto" en ${interviewPath(f)}. Edita la entrevista o corre answer antes de force-ready.`);
  if (!scope.length) throw new Error(`No hay "Scope propuesto" en ${interviewPath(f)}. Edita la entrevista o corre answer antes de force-ready.`);
  f.acceptance = acceptance;
  f.scope = scope;
  f.status = "spec_ready";
  f.manual_spec_ready = true;
  f.manual_spec_ready_at = new Date().toISOString();
  f.manual_spec_ready_reason = "Dev override: Fase 0 marcada como suficientemente especificada pese a suposiciones pendientes.";
  saveSpec(spec);
  console.log(`Feature ${id} → spec_ready por override manual. Revisa y aprueba: spec.mjs approve ${id}`);
}

function approve(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  const by = process.env.USER || process.env.USERNAME || "dev";
  let intv = null;
  if (f.sdd !== false) {
    if (f.status !== "spec_ready") throw new Error(`Feature ${id} debe estar en spec_ready (está en ${f.status}). Completa la entrevista.`);
    intv = readInterview(f);
    f.answers_hash = answersHash(intv.answers);
  }
  f.spec_approved = true; f.approved_by = by; f.approved_at = new Date().toISOString();
  saveSpec(spec);
  const dir = writeSpecFolder(f, intv);
  writeDocsFromSpec(f, intv);
  tryCommit(`spec.json ${dir} docs`, `spec: approve #${f.id} ${f.name}`);
  console.log(`Feature ${id} aprobada por ${by}. Spec durable en ${dir}/ (requirements, design, tasks)`);
}

function done(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.status !== "review_pending") throw new Error(`Feature ${id} no está en review_pending (está en ${f.status}).`);
  f.status = "done"; saveSpec(spec);
  tryCommit("spec.json", `chore: #${f.id} ${f.name} → done`);
  console.log(`Feature ${id} → done. (Para descartarla en su lugar: git revert del commit feat(${f.name}).)`);
}

const [cmd, id] = process.argv.slice(2);
const cmds = { interview, answer, "force-ready": forceReady, approve, done };
if (!cmds[cmd] || !id) { console.log("Uso: node .harness/spec.mjs <interview|answer|force-ready|approve|done> <id>"); process.exit(1); }
cmds[cmd](id);
SPEC_EOF

# ---------------------------------------------------------- orchestrator.mjs
write .harness/orchestrator.mjs <<'ORCH_EOF'
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { loadSpec, loadState, saveState } from "./state.mjs";
import { runGates } from "./gates.mjs";
import { buildInitialPrompt, buildRetryPrompt } from "./prompt.mjs";
import { runAgent } from "./runner.mjs";
import { interviewPath, parseAnswers, answersHash } from "./interview.mjs";

const DRY = process.argv.includes("--dry-run");
const PRI = { P0: 0, P1: 1, P2: 2, P3: 3 };
const PDIR = "progress";
const sh = (cmd) => execSync(cmd, { stdio: "pipe", encoding: "utf8" });

function approvalStale(f) {
  if (f.sdd === false || !f.answers_hash) return false;
  try {
    const md = readFileSync(interviewPath(f), "utf8");
    return answersHash(parseAnswers(md)) !== f.answers_hash;
  } catch { return false; }
}
function consumable(f) {
  if (f.spec_approved !== true) return false;
  if (approvalStale(f)) return false;
  return f.status === "pending" || f.status === "spec_ready";
}

function attemptsTable(attempts) {
  const rows = attempts.map((a) => {
    const fg = a.verdict?.passed ? "—" : (String(a.verdict?.failureOutput || "").match(/Gate fallido: ([^\n]+)/)?.[1] ?? "?");
    return `| ${a.attempt} | ${a.verdict?.passed ? "OK" : "FALLO"} | ${fg} | ${a.tts != null ? a.tts.toFixed(1) : "?"} | ${a.cost ?? "—"} |`;
  }).join("\n");
  return `| intento | resultado | gate fallido | tts(s) | coste |\n|--:|--|--|--:|--:|\n${rows}`;
}

const gateNames = () => { try { return JSON.parse(readFileSync(".harness/gates.config.json", "utf8")).gates.map((g) => g.name); } catch { return []; } };

// review_<name>.md: veredicto + checkpoints derivados de los gates deterministas y del spec SDD.
function writeReview(task, attempts) {
  const last = attempts.at(-1)?.verdict;
  const passed = last?.passed === true;
  const failed = passed ? null : (String(last?.failureOutput || "").match(/Gate fallido: ([^\n]+)/)?.[1] ?? null);
  const names = gateNames();
  const i = failed ? names.indexOf(failed) : names.length;
  const rows = names.map((n, idx) => passed || idx < i ? `- [x] ${n}` : idx === i ? `- [ ] ${n} ← falló` : `- [ ] ${n} (no ejecutado)`);
  const L = [`# Review · ${task.id} · ${task.title}`, "", "## Veredicto", "",
    passed ? `APPROVED → \`${task.status}\`.` : `BLOCKED tras ${attempts.length} intento(s).`, "",
    "## Checkpoints — gates", "", ...rows, ""];
  if (task.sdd !== false) {
    const sd = `spec/${task.id}-${task.name}`;
    L.push("## Checkpoints — SDD", "", ...["requirements", "design", "tasks"].map((f) => `- [${existsSync(`${sd}/${f}.md`) ? "x" : " "}] ${sd}/${f}.md`), "");
    if (task.status === "review_pending") L.push("## Pendiente", "", "- [ ] Smoke test humano (por eso no pasa a `done` automáticamente)", "");
  }
  if (!passed) L.push("## Detalle del fallo", "", "```", String(last?.failureOutput || "").slice(0, 2000), "```", "");
  writeFileSync(`${PDIR}/review_${task.name}.md`, L.join("\n") + "\n");
}

// Memoria de ejecución: impl_<name>.md (append), current.md (snapshot), history.md (append), review_<name>.md.
function writeProgress(task, state, branch) {
  mkdirSync(PDIR, { recursive: true });
  const attempts = state.tasks[task.id]?.attempts ?? [];
  const ts = new Date().toISOString();
  const agent = process.env.HARNESS_AGENT || "claude";
  const table = attemptsTable(attempts);

  const impl = `${PDIR}/impl_${task.name}.md`;
  const prior = existsSync(impl) ? readFileSync(impl, "utf8") : `# Implementación · ${task.id} · ${task.title}\n`;
  writeFileSync(impl, `${prior}\n## ${ts} — estado: ${task.status}\n\n- agente: ${agent} · rama: \`${branch}\` · intentos: ${attempts.length}\n\n${table}\n`);

  const next = task.status === "review_pending" ? `Revisar el diff del commit \`feat(${task.name})\` y cerrar con \`node .harness/spec.mjs done ${task.id}\` (o \`git revert\` para descartarlo).`
    : task.status === "blocked" ? `Revisar \`${impl}\`, ajustar spec o repo y reintentar.`
    : "Feature cerrada. Continúa con la siguiente en cola.";
  writeFileSync(`${PDIR}/current.md`, [`# Sesión actual`, "",
    `Feature: **${task.id} · ${task.name}** — estado: \`${task.status}\`.`, "",
    `- agente: ${agent}`, `- rama: \`${branch}\``, `- intentos: ${attempts.length}`, "",
    "## Siguiente acción", "", `- ${next}`, "", "## Último resultado", "", table, ""].join("\n"));

  const hist = `${PDIR}/history.md`;
  const h0 = existsSync(hist) ? readFileSync(hist, "utf8") : "# Historial de sesiones\n";
  writeFileSync(hist, `${h0}\n## ${ts} — #${task.id} ${task.name} → ${task.status}\n- ${attempts.length} intento(s) · agente ${agent}\n`);

  writeReview(task, attempts);

  try { sh(`git add ${PDIR} spec.json`); sh(`git commit -q -m "docs(progress): #${task.id} ${task.name} → ${task.status}" -- ${PDIR} spec.json`); } catch {}
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

  const dirty = sh("git status --porcelain").trim();
  if (dirty) {
    console.error("⚠️  Working tree no limpio. Commitea o descarta los cambios antes de correr el harness:\n" + dirty);
    process.exit(1);
  }
  const branch = sh("git rev-parse --abbrev-ref HEAD").trim(); // se trabaja EN ESTA rama (sin ramas por feature)

  for (const task of queue) {
    let lastFailure = null, ok = false;
    task.status = "in_progress";
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      const t0 = Date.now();
      const prompt = lastFailure ? buildRetryPrompt(task, lastFailure, attempt) : buildInitialPrompt(task);
      const run = runAgent(prompt, { write: true });
      const verdict = await runGates(task);
      record(state, task.id, { attempt, verdict, tts: (Date.now() - t0) / 1000, cost: run.cost });
      if (verdict.passed) {
        try {
          sh(`git add -A && git commit -q -m "feat(${task.name}): ${task.objective ?? task.name}"`);
        } catch (e) {
          if (!String(e.stdout).includes("nothing to commit")) throw e;
        }
        task.status = task.sdd === false ? "done" : "review_pending";
        if (task.status === "review_pending") console.log(`Feature ${task.id} commiteada en '${branch}' → review_pending. Revisa el diff y cierra con: spec.mjs done ${task.id}`);
        ok = true; break;
      }
      lastFailure = verdict.failureOutput;
      if (attempt < maxAttempts) {
        sh("git reset -q --hard HEAD"); sh("git clean -fdq"); // solo entre reintentos, no en el último
      }
    }
    if (!ok) { task.status = "blocked"; console.error(`⚠️  BLOCKED: ${task.id} ${task.name} falló ${maxAttempts} veces.`); console.error(state.tasks[task.id]?.attempts.at(-1)?.verdict?.failureOutput ?? ""); }
    saveState(state);
    writeFileSync("spec.json", JSON.stringify(spec, null, 2));
    writeProgress(task, state, branch);
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
const ALWAYS = ["docs/", "spec/", "progress/", ".harness/"]; // memoria: siempre permitida fuera del scope

function run(cmd) {
  try { return { ok: true, out: execSync(cmd, { stdio: "pipe", encoding: "utf8" }) }; }
  catch (e) { return { ok: false, out: (e.stdout ?? "") + (e.stderr ?? "") }; }
}
function diffScopeGate(task) {
  const declared = task.scope ?? [];
  if (declared.length === 0) return { ok: true, out: "" };
  const changed = execSync("git status --porcelain -uall", { encoding: "utf8" })
    .split("\n").map((l) => unquoteStatusPath(l.slice(3).trim())).filter(Boolean)
    .map((p) => (p.includes(" -> ") ? p.split(" -> ")[1] : p)); // archivos modificados Y nuevos
  const allowed = [...declared, ...ALWAYS];
  const outside = changed.filter((f) => !allowed.some((p) => {
    const prefix = p.replace(/\/\*\*?$/, "/").replace(/\*$/, "");
    return f.startsWith(prefix);
  }));
  return outside.length === 0 ? { ok: true, out: "" } : { ok: false, out: `Archivos fuera de scope: ${outside.join(", ")}` };
}
function unquoteStatusPath(path) {
  if (path.startsWith('"') && path.endsWith('"')) {
    return JSON.parse(path);
  }
  return path;
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
    `Lee el spec completo en spec/${task.id}-${task.name}/ (requirements.md, design.md, tasks.md).`,
    `id: ${task.id}  name: ${task.name}`,
    `Título: ${task.title}`,
    `Descripción: ${task.description}`,
    task.scope?.length ? `SOLO puedes tocar: ${task.scope.join(", ")} (además de docs/ y spec/ para registrar decisiones y marcar tareas).` : "",
    "Criterios de aceptación:",
    ...(task.acceptance ?? []).map((a, i) => `  ${i + 1}. ${a}`),
    `Marca [x] en spec/${task.id}-${task.name}/tasks.md las tareas que completes.`,
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
  STACK="node/ts"; TEST_CMD="npm test --silent"
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
if [ -e spec.json ] && [ "$FORCE" -ne 1 ]; then say "salto spec.json (ya existe)"; else
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

El agente lee esta carpeta antes de implementar. `spec.mjs approve` añade contexto mínimo automáticamente
a `ARCHITECTURE.md` y `DECISIONS.md`, pero el dev debe rellenar la parte de visión y convenciones del repo.

Mínimo útil antes de la primera feature:

1. En `ARCHITECTURE.md`, completa objetivo del producto, componentes existentes y restricciones conocidas.
2. En `CONVENTIONS.md`, completa cómo se ejecuta, testea y despliega este repo.
3. En `DECISIONS.md`, deja cualquier decisión que no deba redescubrir otro agente.
EOF
seed docs/ARCHITECTURE.md <<'EOF'
# Arquitectura

> El agente lo lee antes de implementar. Mantén aquí el contexto que no cabe en una feature concreta.

## Visión general

Producto/proyecto:

Usuarios principales:

Objetivo no negociable:

## Componentes

- (rellenar) Componente:
  - Responsabilidad:
  - Entradas/salidas:
  - Dueño/riesgo:

## Flujo de datos

1. (rellenar)

## Integraciones externas

- (rellenar) Servicio/API:
  - Contrato:
  - Credenciales/config:
  - Entorno local/CI:

## Restricciones conocidas

- (rellenar) Rendimiento, seguridad, compatibilidad, despliegue, coste, etc.

## Decisiones abiertas

- (rellenar) Preguntas que bloquean diseño futuro.

<!-- Los specs aprobados se anexan debajo con marcadores harness:<id>. -->
EOF
seed docs/DECISIONS.md <<'EOF'
# Decisiones (ADR)

Formato por entrada: **fecha · título** — contexto, decisión y consecuencias.
El harness añade entradas cuando se aprueba un spec; el agente también debe añadir entradas cuando toma
una decisión de arquitectura relevante durante implementación.

## Pendientes de decisión

- (rellenar) Decisiones que aún no deben asumirse automáticamente.

<!-- Nuevas entradas debajo -->
EOF
seed docs/CONVENTIONS.md <<'EOF'
# Convenciones

- Metodología: SDD (una feature a la vez, spec aprobado antes de implementar).
- Sin ramas por feature: el harness trabaja en la rama actual y commitea cada feature ahí (`feat(<name>): <título>`). Para aislar una corrida entera, usa un `git worktree`.
- Una feature `sdd:true` queda en `review_pending` tras implementar; revisas el diff y la cierras con `spec.mjs done` (o `git revert` para descartarla).
- Tests obligatorios para cerrar una feature.

## Estilo de código

Lenguaje/framework principal:

Gestor de paquetes:

Comandos locales:

- Instalar:
- Lint:
- Typecheck/build:
- Test:
- Dev server:

Estructura relevante:

- (rellenar) Carpeta:
  - Propósito:

Reglas de diseño/API:

- (rellenar)

Reglas de tests:

- (rellenar)

Reglas de despliegue:

- (rellenar)
EOF

seed spec/README.md <<'EOF'
# spec/ — Specs aprobados (durables, versionados)

`spec.json` (raíz) es la cola viva. Aquí queda el spec **aprobado** de cada feature, en una subcarpeta
`<id>-<name>/` con tres archivos (estructura SDD):

- `requirements.md` — el QUÉ: contexto, requisitos funcionales (R1, R2…) y restricciones.
- `design.md` — el CÓMO: scope, enfoque por dimensión y decisiones de la entrevista.
- `tasks.md` — el desglose: checklist que el agente marca al implementar.

Los genera `spec.mjs approve`.
EOF

seed progress/README.md <<'EOF'
# progress/ — Memoria de ejecución

- `current.md` — snapshot de la sesión activa: feature en curso, estado y siguiente acción. Se sobrescribe.
- `history.md` — historial datado de cierres de feature. Se va anexando.
- `impl_<name>.md` — registro de implementación por feature: intentos, gate que falló, tiempo y coste.
- `review_<name>.md` — veredicto (APPROVED/BLOCKED) con checkpoints derivados de los gates y del spec SDD.

Lo genera el orquestador automáticamente. (`.harness/harness-state.json` es el log crudo por máquina y NO
se versiona; esto es el resumen curado que sí.)
EOF
seed progress/current.md <<'EOF'
# Sesión actual

Sin feature en curso todavía. Aprueba un spec y corre `node .harness/orchestrator.mjs`.
EOF
seed progress/history.md <<'EOF'
# Historial de sesiones

EOF

step "Punteros CLAUDE.md / AGENTS.md"
POINTER=$'# Instrucciones del repo\n\nAntes de actuar, lee `HARNESS.md` y síguelo.\nSi falta el directorio `.harness/`, instálalo con `bash init.sh`.\nLee `docs/` para el contexto del proyecto antes de implementar.\nNunca implementes una feature cuyo spec no esté aprobado (`spec_approved: true`).\n'
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
   node .harness/spec.mjs interview 1 # escribe .harness/interviews/<id>-<name>.md
   #   responde los **R:** en ese archivo
   node .harness/spec.mjs answer 1    # integra respuestas + pase adversarial → spec_ready
   node .harness/spec.mjs approve 1   # → escribe spec/<id>-<name>/{requirements,design,tasks}.md
   node .harness/orchestrator.mjs     # → escribe progress/{current,history,impl_<name>}.md

   ⚠️ Para aislar la corrida usa un git worktree/contenedor (HARNESS_UNATTENDED=1 da escritura sin confirmación).
DONE
