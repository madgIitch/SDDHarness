# HARNESS.md — Bootstrap del SDD Harness (agnóstico de repo y de agente)

> **Para el agente que lee este archivo** (seas Claude Code o Codex): este documento es una instrucción
> ejecutable. Si falta el directorio `.harness/`, tu primera tarea es **instalar el harness siguiendo el
> checklist de la sección 4**, sin pedir confirmación salvo en los puntos marcados con ⚠️. Si ya está
> instalado, ve a la sección 9 (Operación). Nunca implementes una feature cuyo spec no esté **aprobado**
> por el dev (`spec_approved: true`).

Este harness es portable: cae en cualquier repo nuevo y se autoconfigura. No asume lenguaje, framework ni
proveedor de modelo. Funciona con **Claude Code** (`claude -p`) y con **Codex** (`codex exec`) a través de
una única capa `runner.mjs`.

---

## 1. Qué es esto

Dos bucles encadenados sobre un spec SDD (JSON):

```
FASE 0 — autoría del spec (solo features sdd:true)
  borrador → entrevista (agente ↔ dev) → spec_ready → [APROBACIÓN DEL DEV] ─┐
                                                                            │
FASE 1 — implementación (solo features aprobadas)                          ▼
  in_progress → agente headless → gates deterministas → review_pending / blocked
                      ▲                                                     │
                      └──────────────── retry con feedback ─────────────────┘
```

Principios no negociables:

1. **El spec se concreta antes de implementar.** Una feature `sdd:true` no llega a implementación sin pasar entrevista + aprobación humana.
2. **El evaluador es determinista primero.** Un LLM solo juzga criterios blandos, nunca lo que un test puede verificar.
3. **Una feature a la vez** (`rules.one_feature_at_a_time`). Branch por feature.
4. **Presupuesto de fallos.** N intentos por tarea (def. 3), luego `blocked` con contexto. Nunca bucle infinito.
5. **El humano sigue en el loop** en dos puntos: aprobar el spec y revisar la implementación (`review_pending`).
6. **Agnóstico de agente.** El mismo bucle corre con Claude o Codex; el agente se elige con `HARNESS_AGENT`.
7. **Todo lo medible se mide:** TTS, tokens/coste (cuando el agente lo expone), intentos y gates, por tarea.

---

## 2. Agente: Claude o Codex

Se elige por variable de entorno (default `claude`):

```bash
export HARNESS_AGENT=claude   # usa: claude -p ... --output-format json
export HARNESS_AGENT=codex    # usa: codex exec ...
export HARNESS_UNATTENDED=1   # ⚠️ desactiva prompts de permiso (solo en branch/worktree aislado)
```

Diferencias que el `runner.mjs` absorbe:

| | Claude Code | Codex |
|---|---|---|
| Invocación | `claude -p <prompt>` | `codex exec <prompt>` |
| Salida | objeto JSON (`--output-format json`) → campo `result` | mensaje final del agente en **stdout** (progreso va a stderr) |
| Solo lectura (Fase 0) | `--allowedTools "Read,Grep,Glob"` | `-s read-only` |
| Escritura (Fase 1) | `--allowedTools "Edit,Write,Bash,Read,Grep,Glob"` | `-s workspace-write` |
| Sin prompts (unattended) | `--dangerously-skip-permissions` | `--approval-policy never` |
| Coste por corrida | `total_cost_usd` en el JSON | no se expone en stdout → métrica `null` |

> El harness debe correr en una **branch/worktree aislada** (o contenedor). El modo unattended da al agente
> permiso de escritura sin confirmación; nunca lo ejecutes sobre tu rama principal con credenciales de producción ⚠️.

---

## 3. Formato del spec (`spec.json`)

Esquema genérico. Reutilízalo en cualquier repo:

```json
{
  "project": "my-new-repo",
  "description": "Descripción corta del proyecto",
  "rules": {
    "one_feature_at_a_time": true,
    "require_tests_to_close": true,
    "require_approved_spec_to_implement": true,
    "valid_status": ["pending", "spec_ready", "in_progress", "review_pending", "done", "blocked"],
    "sdd_required_when": "feature tiene \"sdd\": true",
    "max_attempts": 3
  },
  "features": [
    {
      "id": 1,
      "name": "ci_setup",
      "title": "Configurar CI básico (lint + test)",
      "description": "Tarea mecánica, sin diseño que discutir.",
      "priority": "P0",
      "sdd": false,
      "status": "pending"
    },
    {
      "id": 2,
      "name": "user_auth_endpoint",
      "title": "Endpoint de autenticación de usuario",
      "description": "Diseño no trivial: contratos, errores, sesiones.",
      "acceptance": ["...", "..."],
      "priority": "P1",
      "sdd": true,
      "status": "pending"
    }
  ]
}
```

- `sdd: false` → tarea mecánica: sin entrevista, aprobación de un toque, merge automático al pasar gates.
- `sdd: true` → pasa por Fase 0 completa (entrevista + aprobación) y queda en `review_pending` tras implementar.

**Campos que el harness añade** (additivos): `scope` (paths permitidos, lo escribe la entrevista),
`spec_approved`/`approved_by`/`approved_at` (aprobación), `answers_hash` (invalida la aprobación si el spec
cambia después). La conversación de la entrevista vive en `.harness/interviews/<id>.json`, no en `spec.json`.

---

## 4. Checklist de bootstrap (ejecutar si falta `.harness/`)

- [ ] Crear el árbol de la sección 5.
- [ ] Escribir los seis scripts de la sección 6 (incluido `runner.mjs`).
- [ ] Detectar el stack (sección 7) y rellenar `.harness/gates.config.json`.
- [ ] Si `rules.require_tests_to_close === true`, verificar que existe un gate de tests; si no, **avisar** ⚠️.
- [ ] Crear `spec.json` con el bloque `rules` (sección 3) si no existe.
- [ ] Crear/actualizar `CLAUDE.md` **y** `AGENTS.md` con el puntero de la sección 8.
- [ ] Añadir las entradas de `.gitignore` de la sección 10.
- [ ] Verificar que el CLI del agente elegido existe: `claude --version` o `codex --version`. Si falta, **detener y avisar** ⚠️.
- [ ] Dry-run: `node .harness/orchestrator.mjs --dry-run` y reportar la cola.
- [ ] **No** correr el harness en real sin aprobación humana ⚠️.

---

## 5. Estructura de archivos

```
.harness/
  runner.mjs             # capa agnóstica de agente (claude | codex)
  orchestrator.mjs       # bucle de implementación (Fase 1)
  spec.mjs               # entrevista + aprobación (Fase 0)
  gates.mjs              # evaluador determinista
  prompt.mjs             # prompts de implementación
  state.mjs              # I/O de spec.json y harness-state.json
  gates.config.json      # gates por stack
  harness-state.json     # estado/métricas (gitignored)
  interviews/<id>.json   # sidecars de entrevista (gitignored)
spec.json
CLAUDE.md                # puntero a HARNESS.md (Claude Code lo auto-carga)
AGENTS.md                # puntero a HARNESS.md (Codex lo auto-carga)
HARNESS.md
```

---

## 6. Scripts a crear

### 6.1 `.harness/runner.mjs` — capa agnóstica de agente

```javascript
import { execSync } from "node:child_process";

const AGENT = (process.env.HARNESS_AGENT || "claude").toLowerCase(); // "claude" | "codex"
const UNATTENDED = process.env.HARNESS_UNATTENDED === "1";

const q = (s) => JSON.stringify(s); // comillas seguras para el shell
const sh = (cmd) =>
  execSync(cmd, { stdio: ["ignore", "pipe", "inherit"], encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });

// runAgent → { text, cost } sea cual sea el proveedor.
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
  // codex exec imprime SOLO el mensaje final en stdout; el progreso va a stderr.
  const sandbox = write ? "workspace-write" : "read-only";
  const approval = UNATTENDED || write ? "--approval-policy never" : "";
  const text = sh(`codex exec ${approval} -s ${sandbox} ${q(prompt)}`);
  return { text: text.trim(), cost: null }; // Codex no expone coste en stdout
}

// Extrae el primer objeto JSON del texto del agente (tolerante a fences/preámbulo).
export function extractJson(text) {
  const clean = text.replace(/```json|```/g, "").trim();
  const a = clean.indexOf("{"), b = clean.lastIndexOf("}");
  if (a === -1 || b === -1) throw new Error("El agente no devolvió JSON:\n" + text.slice(0, 500));
  return JSON.parse(clean.slice(a, b + 1));
}
```

### 6.2 `.harness/spec.mjs` — Fase 0 (entrevista + aprobación)

```javascript
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { runAgent, extractJson } from "./runner.mjs";

const SPEC = "spec.json";
const IDIR = ".harness/interviews";

// Dimensiones genéricas que toda feature sdd:true debe resolver (o levantar pregunta).
const DIMENSIONS = [
  "data_model",          // esquema/contrato de datos afectado
  "error_states",        // fallos y su manejo
  "edge_cases",          // casos límite, concurrencia, idempotencia
  "auth_secrets",        // auth, permisos, env vars/secrets
  "external_contracts",  // APIs, firmas, herramientas externas
  "ui_states",           // loading/empty/error/success (si hay UI)
  "rollback_compat",     // rollback y compatibilidad hacia atrás
  "tests",               // criterios de aceptación testables
];

const sh = (cmd) => execSync(cmd, { stdio: "pipe", encoding: "utf8" });
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

function interview(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.sdd === false) {
    console.log(`Feature ${id} es sdd:false → sin entrevista. Apruébala: spec.mjs approve ${id}`);
    return;
  }
  const prior = existsSync(scPath(id)) ? loadSc(id) : { answers: {} };
  const res = ask([
    "Eres entrevistador de especificaciones (SDD). NO escribas código. Devuelve SOLO JSON.",
    "Analiza el repo (solo lectura) y esta feature:",
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
  else {
    console.log(`PREGUNTAS ABIERTAS (feature ${id}):`);
    open.forEach((d) => console.log(`  [${d}] ${sc.dimensions[d].question}`));
    console.log(`\nResponde en "answers" de ${scPath(id)} y corre: spec.mjs answer ${id}`);
  }
}

function answer(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  const sc = loadSc(id);

  // 1) Revisar el spec integrando las respuestas del dev.
  const revised = ask([
    "Revisa esta spec integrando las respuestas del dev. NO escribas código. Devuelve SOLO JSON (mismo formato).",
    `Feature: ${JSON.stringify({ id: f.id, title: f.title, description: f.description })}`,
    `Borrador: ${JSON.stringify({ dimensions: sc.dimensions, scope: sc.scope, acceptance: sc.acceptance })}`,
    `Respuestas del dev: ${JSON.stringify(sc.answers)}`,
  ].join("\n"));

  // 2) Pase adversarial: un implementador busca dónde tendría que adivinar.
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
  f.acceptance = revised.acceptance;
  f.scope = revised.scope;
  f.status = "spec_ready";
  saveSpec(spec);
  console.log(`Feature ${id} → spec_ready. Revísala y aprueba: spec.mjs approve ${id}`);
}

function approve(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  const by = process.env.USER || process.env.USERNAME || "dev";
  if (f.sdd !== false) {
    const sc = loadSc(id);
    if (!sc.ready) throw new Error(`Feature ${id}: spec no listo (ready:false).`);
    if (f.status !== "spec_ready") throw new Error(`Feature ${id} debe estar en spec_ready (está en ${f.status}).`);
    f.answers_hash = "sha256:" + createHash("sha256").update(JSON.stringify(sc.answers)).digest("hex");
  }
  f.spec_approved = true;
  f.approved_by = by;
  f.approved_at = new Date().toISOString();
  saveSpec(spec);
  console.log(`Feature ${id} aprobada por ${by}.`);
}

function done(id) {
  const spec = loadSpec();
  const f = feature(spec, id);
  if (f.status !== "review_pending") throw new Error(`Feature ${id} no está en review_pending (está en ${f.status}).`);
  if (f.sdd !== false) sh(`git merge --no-ff harness/${f.name}`);
  f.status = "done";
  saveSpec(spec);
  console.log(`Feature ${id} → done.`);
}

const [cmd, id] = process.argv.slice(2);
const cmds = { interview, answer, approve, done };
if (!cmds[cmd] || !id) { console.log("Uso: node .harness/spec.mjs <interview|answer|approve|done> <id>"); process.exit(1); }
cmds[cmd](id);
```

### 6.3 `.harness/orchestrator.mjs` — Fase 1 (implementación)

```javascript
import { execSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { loadSpec, loadState, saveState } from "./state.mjs";
import { runGates } from "./gates.mjs";
import { buildInitialPrompt, buildRetryPrompt } from "./prompt.mjs";
import { runAgent } from "./runner.mjs";

const DRY = process.argv.includes("--dry-run");
const PRI = { P0: 0, P1: 1, P2: 2, P3: 3 };
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

  for (const task of queue) { // one_feature_at_a_time
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
        else { sh("git checkout -"); task.status = "review_pending";
          console.log(`Feature ${task.id} en ${branch} → review_pending. Cierra con: spec.mjs done ${task.id}`); }
        ok = true; break;
      }
      lastFailure = verdict.failureOutput;
      sh(`git checkout - && git branch -D ${branch}`);
    }

    if (!ok) {
      task.status = "blocked";
      console.error(`⚠️  BLOCKED: ${task.id} ${task.name} falló ${maxAttempts} veces.`);
      console.error(state.tasks[task.id]?.attempts.at(-1)?.verdict?.failureOutput ?? "");
    }
    saveState(state);
    writeFileSync("spec.json", JSON.stringify(spec, null, 2));
  }
}

function record(state, id, entry) { state.tasks[id] ??= { attempts: [] }; state.tasks[id].attempts.push(entry); }
main().catch((e) => { console.error("Harness error:", e); process.exit(1); });
```

### 6.4 `.harness/gates.mjs`

```javascript
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const cfg = JSON.parse(readFileSync(new URL("./gates.config.json", import.meta.url)));
function run(cmd) {
  try { return { ok: true, out: execSync(cmd, { stdio: "pipe", encoding: "utf8" }) }; }
  catch (e) { return { ok: false, out: (e.stdout ?? "") + (e.stderr ?? "") }; }
}
function diffScopeGate(task) {
  const changed = execSync("git diff --name-only HEAD", { encoding: "utf8" }).split("\n").filter(Boolean);
  const allowed = task.scope ?? [];
  if (allowed.length === 0) return { ok: true, out: "" };
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
```

### 6.5 `.harness/state.mjs`

```javascript
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const STATE = ".harness/harness-state.json";
export const loadSpec = () => JSON.parse(readFileSync("spec.json", "utf8"));
export const loadState = () => existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : { tasks: {}, startedAt: new Date().toISOString() };
export const saveState = (s) => writeFileSync(STATE, JSON.stringify(s, null, 2));
```

### 6.6 `.harness/prompt.mjs`

```javascript
export function buildInitialPrompt(task) {
  return [
    "Implementa esta feature (metodología SDD). El spec ya fue aprobado por el dev.",
    `id: ${task.id}  name: ${task.name}`,
    `Título: ${task.title}`,
    `Descripción: ${task.description}`,
    task.scope?.length ? `SOLO puedes tocar: ${task.scope.join(", ")}` : "",
    "Criterios de aceptación:",
    ...(task.acceptance ?? []).map((a, i) => `  ${i + 1}. ${a}`),
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
```

---

## 7. Detección de stack y gates

El agente inspecciona el repo y rellena `.harness/gates.config.json`:

| Señal | Stack | Gates |
|---|---|---|
| `tsconfig.json` + `package.json` | **Node/TS** (o Expo/RN) | `tsc --noEmit`, `eslint`, test runner detectado, `diff-scope` |
| `supabase/functions/**/*.ts` | **Supabase Edge (Deno)** | `deno check`, `deno lint`, `deno test`, `diff-scope` |
| `pyproject.toml` / `requirements.txt` | **Python** | `ruff check`, `mypy`, `pytest`, `diff-scope` |
| `go.mod` | **Go** | `go vet`, `go build ./...`, `go test ./...`, `diff-scope` |
| `Cargo.toml` | **Rust** | `cargo clippy`, `cargo build`, `cargo test`, `diff-scope` |

Plantilla (Node/TS):

```json
{
  "gates": [
    { "name": "typecheck", "cmd": "npx tsc --noEmit", "blocking": true },
    { "name": "lint", "cmd": "npx eslint . --format unix", "maxWarnings": 0, "warningPattern": "warning", "blocking": true },
    { "name": "test", "cmd": "npm test --silent", "blocking": true },
    { "name": "diff-scope", "blocking": true }
  ]
}
```

Orden = coste: lo barato primero. Un gate bloqueante que falla corta la cadena. Si
`rules.require_tests_to_close === true`, debe existir un gate de tests; si no, el bootstrap avisa ⚠️.

---

## 8. Punteros para que el agente lea esto (`CLAUDE.md` y `AGENTS.md`)

Claude Code auto-carga `CLAUDE.md`; Codex auto-carga `AGENTS.md`. Crea **ambos** con el mismo contenido:

```markdown
# Instrucciones del repo

Antes de actuar, lee `HARNESS.md` y síguelo.
Si falta el directorio `.harness/`, instálalo siguiendo la sección 4 de `HARNESS.md`.
Nunca implementes una feature cuyo spec no esté aprobado (`spec_approved: true`).
```

---

## 9. Operación

```bash
export HARNESS_AGENT=claude        # o codex

# Fase 0 — concretar y aprobar (solo sdd:true necesita interview/answer)
node .harness/spec.mjs interview 2     # genera preguntas por dimensión
#   → responde en .harness/interviews/2.json (campo "answers")
node .harness/spec.mjs answer 2        # integra respuestas + pase adversarial → spec_ready
node .harness/spec.mjs approve 2       # sella la aprobación (approve directo si sdd:false)

# Fase 1 — implementación
node .harness/orchestrator.mjs --dry-run
node .harness/orchestrator.mjs
node .harness/spec.mjs done 2          # tras revisar la branch harness/<name>
```

---

## 10. `.gitignore`

```
.harness/harness-state.json
.harness/interviews/
```

`spec.json`, los scripts, `CLAUDE.md` y `AGENTS.md` sí se versionan.

---

## 11. Métricas

Cada entrada de `harness-state.json` da, por tarea e intento: `tts` (segundos reales), `cost` (solo con
Claude; `null` con Codex), `attempt` y el `verdict` de cada gate. Permite calcular de forma reproducible:
tiempo medio por feature, tasa de éxito al primer intento vs. tras retry, coste agregado y qué gate falla más.

---

## 12. Límites conocidos

- La confianza autorreportada del modelo es señal débil. Los gates reales de la entrevista son la **cobertura de dimensiones** y el **pase adversarial de implementador**, no un score.
- El coste por corrida solo se mide con Claude; con Codex queda `null` (no lo expone en stdout — habría que parsear el rollout JSONL de la sesión).
- El LLM-as-judge (si lo añades como gate no bloqueante) **no está validado** contra juicio humano. Revisa una muestra de sus veredictos periódicamente.
- `diff-scope` solo sirve si el `scope` está bien acotado. Un scope demasiado amplio lo vuelve inútil.
- La ejecución es secuencial (`one_feature_at_a_time`). Para features que tocan contratos compartidos, secuéncialas: no las apruebes a la vez.
- El harness asume una branch/worktree aislada. En modo unattended el agente escribe sin confirmación; no lo corras sobre la rama principal ni con credenciales sensibles ⚠️.
