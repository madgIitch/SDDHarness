# HARNESS.md — SDD Harness (agnóstico de repo y de agente)

> **Para el agente que lee este archivo** (seas Claude Code o Codex):
> 1. Si falta el directorio `.harness/`, instálalo ejecutando **`bash init.sh`** (ver sección 5). No reescribas
>    los scripts a mano: `init.sh` es el generador canónico y probado.
> 2. Antes de implementar cualquier feature, lee `docs/` para tener el contexto del proyecto.
> 3. Nunca implementes una feature cuyo spec no esté **aprobado** por el dev (`spec_approved: true`).

Este harness cae en cualquier repo nuevo y se autoconfigura. No asume lenguaje, framework ni proveedor de
modelo. Funciona con **Claude Code** (`claude -p`) y con **Codex** (`codex exec`) tras una única capa
`runner.mjs`. Acumula memoria del proyecto en `docs/`, `spec/` y `progress/`.

---

## 1. Qué es esto

Dos bucles encadenados sobre un spec SDD (JSON), con una capa de memoria que persiste entre corridas:

```
FASE 0 — autoría del spec (solo features sdd:true)
  borrador → entrevista (agente ↔ dev) → spec_ready → [APROBACIÓN DEL DEV] ──┐
                                                       └─→ escribe spec/<id>/{requirements,design,tasks}.md
                                                                             │
FASE 1 — implementación (solo features aprobadas)                           ▼
  in_progress → agente headless → gates deterministas → review_pending / blocked
       │ (lee docs/)                                    └─→ escribe progress/{current,history,impl}.md
       ▲                                                                     │
       └──────────────────────── retry con feedback ─────────────────────────┘
```

Principios no negociables:

1. **El spec se concreta antes de implementar.** Una feature `sdd:true` no llega a implementación sin pasar entrevista + aprobación humana.
2. **El evaluador es determinista primero.** Un LLM solo juzga criterios blandos, nunca lo que un test puede verificar.
3. **Una feature a la vez** (`rules.one_feature_at_a_time`). Sin ramas por feature: se commitea en sitio sobre la rama actual.
4. **Presupuesto de fallos.** N intentos por tarea (def. 3), luego `blocked` con contexto. Nunca bucle infinito.
5. **El humano sigue en el loop** en dos puntos: aprobar el spec y revisar la implementación (`review_pending`).
6. **Agnóstico de agente.** El mismo bucle corre con Claude o Codex; se elige con `HARNESS_AGENT`.
7. **Memoria persistente.** Cada decisión y cada corrida quedan documentadas y versionadas.

---

## 2. Agente: Claude o Codex

Se elige por variable de entorno (default `claude`). El `runner.mjs` absorbe las diferencias de CLI:

```bash
export HARNESS_AGENT=claude   # usa: claude -p --output-format json (prompt por stdin)
export HARNESS_AGENT=codex     # usa: codex exec -s ... -      (prompt por stdin)
export HARNESS_UNATTENDED=1   # desactiva prompts de permiso (solo en worktree/contenedor aislado)

# Si el CLI no se resuelve (típico en Windows/PowerShell), fija la ruta exacta:
export HARNESS_CODEX_BIN='C:\ruta\codex.exe'    # o HARNESS_CLAUDE_BIN
export HARNESS_TIMEOUT_MS=900000                # tope por corrida (def. 15 min)
```

| | Claude Code | Codex |
|---|---|---|
| Invocación | `claude -p --output-format json` | `codex exec -s <sandbox> -` |
| Prompt | por **stdin** (no como argumento) | por **stdin** (flag `-`) |
| Salida | objeto JSON (`result`) | mensaje final en stdout |
| Solo lectura (Fase 0) | `--allowedTools "Read,Grep,Glob"` | `-s read-only` |
| Escritura (Fase 1) | `--allowedTools "Edit,Write,Bash,..."` | `-s workspace-write` |
| Sin prompts (unattended) | `--dangerously-skip-permissions` | `--approval-policy never` |
| Coste por corrida | `total_cost_usd` en el JSON | no se expone → métrica `null` |

El prompt se pasa **por stdin** (`spawnSync` con `input`), no como argumento: esto evita problemas de
comillas y saltos de línea en `cmd.exe`, y al cerrar stdin entrega el EOF que evita el cuelgue conocido de
`codex exec` cuando lo lanza un proceso hijo no interactivo. En Windows el runner usa `shell:true` para
resolver los shims `.cmd`/`.exe`; si aun así no encuentra el CLI, fija `HARNESS_CODEX_BIN`/`HARNESS_CLAUDE_BIN`.

Como no usa ramas por feature, si quieres aislar una corrida entera hazlo con un **`git worktree`** o contenedor. En modo unattended el agente
escribe sin confirmación; aíslalo del entorno con credenciales de producción ⚠️.

---

## 3. Memoria del proyecto (`docs/` · `spec/` · `progress/`)

Tres carpetas **versionadas** que dan continuidad entre corridas. El bucle se cierra solo: el agente *lee*
`docs/` antes de implementar → implementa → el resultado se *escribe* en `progress/`, y las decisiones
relevantes vuelven a `docs/`.

| Carpeta | Qué guarda | Quién escribe |
|---|---|---|
| `docs/` | Conocimiento durable: `ARCHITECTURE.md`, `DECISIONS.md` (ADR), `CONVENTIONS.md` | el dev y el agente (registra decisiones) |
| `spec/` | El spec **aprobado** de cada feature en una subcarpeta `<id>-<name>/` con `requirements.md` (el qué), `design.md` (el cómo) y `tasks.md` (checklist) | `spec.mjs approve` |
| `progress/` | `current.md` (snapshot), `history.md` (historial datado), `impl_<name>.md` (intentos, gate, TTS, coste) y `review_<name>.md` (veredicto + checkpoints) por feature | el orquestador |

Notas de diseño:

- El gate `diff-scope` lleva `docs/`, `spec/` y `progress/` en una **allowlist permanente**: sin ella, el agente fallaría la feature al registrar una decisión en `docs/DECISIONS.md`.
- Los commits de memoria son **path-limited** (`git commit -- progress`), así que no arrastran cambios a medias en otros archivos.
- `.harness/harness-state.json` (log crudo por máquina) y los sidecars de entrevista **no** se versionan; la memoria curada (`docs/spec/progress`) **sí**.

---

## 4. Formato del spec (`spec.json`)

```json
{
  "project": "my-new-repo",
  "description": "Descripción corta",
  "rules": {
    "one_feature_at_a_time": true,
    "require_tests_to_close": true,
    "require_approved_spec_to_implement": true,
    "valid_status": ["pending", "spec_ready", "in_progress", "review_pending", "done", "blocked"],
    "sdd_required_when": "feature tiene \"sdd\": true",
    "max_attempts": 3
  },
  "features": [
    { "id": 1, "name": "ci_setup", "title": "CI básico", "description": "Mecánica.", "priority": "P0", "sdd": false, "status": "pending" },
    { "id": 2, "name": "user_auth", "title": "Auth de usuario", "description": "Diseño no trivial.", "acceptance": [], "priority": "P1", "sdd": true, "status": "pending" }
  ]
}
```

- `sdd: false` → tarea mecánica: sin entrevista, aprobación de un toque, se cierra a `done` automáticamente al pasar gates.
- `sdd: true` → pasa por Fase 0 completa y queda en `review_pending` tras implementar.

**Campos que el harness añade** (additivos): `scope` (paths permitidos, lo escribe la entrevista),
`spec_approved`/`approved_by`/`approved_at` (aprobación), `answers_hash` (invalida la aprobación si el spec
cambia después). La entrevista vive como Markdown editable en `.harness/interviews/<id>-<name>.md` (el dev responde en líneas `**R:**`), no en `spec.json`.

---

## 5. Bootstrap

```bash
bash init.sh            # instala .harness/ + memoria, detecta el stack, escribe punteros y .gitignore
bash init.sh --force    # además reescribe los scripts de .harness/
```

`init.sh` es idempotente: salta `spec.json`, la memoria y los punteros si ya existen. Requiere `git`, `node`
y el CLI del agente elegido (avisa si falta, no aborta). Crea este árbol:

```
.harness/  runner.mjs orchestrator.mjs spec.mjs gates.mjs prompt.mjs state.mjs
           interview.mjs gates.config.json  harness-state.json(gitignored)  interviews/(gitignored, .md)
spec.json
docs/      README ARCHITECTURE DECISIONS CONVENTIONS
spec/      README + <id>-<name>/{requirements,design,tasks}.md por feature aprobada
progress/  README current.md history.md + impl_<name>.md y review_<name>.md por feature
CLAUDE.md  AGENTS.md   (punteros a este HARNESS.md, auto-cargados por cada agente)
HARNESS.md
```

Tras instalar: rellena `docs/ARCHITECTURE.md` y `docs/CONVENTIONS.md` con el contexto del repo.

---

## 6. Máquina de estados (`valid_status`)

```
pending ──(sdd:false)─────────────────────────────────┐
   │                                                   │
   └─(sdd:true) interview → spec_ready                 │
                              │                         │
                     [APROBACIÓN] ←─────────────────────┘  spec.mjs approve → spec/<id>/
                              │
                          in_progress  ← orquestador (lee docs/)
                              │
                  ┌───────────┴───────────┐
              gates pass                N fallos
                  │                         │
   commit feat() en la rama actual (intento fallido → reset --hard + clean)
        (sdd:false) done            (sdd:true) review_pending ──done──▶  blocked
                              (cada cierre → current · history · impl_<name> · review_<name>)
```

`blocked` es escalada: el dev revisa el último `failureOutput` en `progress/impl_<name>.md` o
`harness-state.json`, ajusta el spec o el repo, y vuelve a poner la feature en cola.

---

## 7. Fase 0 — concretar y aprobar (solo `sdd:true`)

La entrevista es una invocación **de solo lectura** que no edita código; produce salida estructurada que el
harness verifica. El forcing de preguntas no se basa en pedirlas (eso da relleno), sino en dos mecanismos:

1. **Cobertura por dimensiones.** Para cada dimensión [`data_model`, `error_states`, `edge_cases`, `auth_secrets`, `external_contracts`, `ui_states`, `rollback_compat`, `tests`] el agente la resuelve o levanta una pregunta. El harness rechaza el spec si queda alguna sin cubrir. Si el agente omite una dimensión, el harness la trata como no cubierta.
2. **Pase adversarial de implementador.** Una segunda invocación —que recibe tus respuestas y la cobertura— lista los puntos donde un implementador todavía tendría que tomar una decisión material. Se anotan como **suposiciones** en el `.md` (sección "Suposiciones del implementador"), para revisarlas antes de aprobar.

La readiness (`spec_ready`) se decide **solo por la cobertura de las 8 dimensiones**. Las suposiciones del pase adversarial son avisos, no bloquean: las ves antes de aprobar y decides si ajustas el spec. La aprobación es del dev, auditada con `answers_hash` (si editas las respuestas después, la aprobación se invalida sola).

---

## 8. Operación

```bash
export HARNESS_AGENT=claude        # o codex

# Fase 0 (solo sdd:true)
node .harness/spec.mjs interview 2     # escribe interviews/2-<name>.md con preguntas
#   responde los **R:** en ese .md
node .harness/spec.mjs answer 2        # integra + pase adversarial → spec_ready
node .harness/spec.mjs approve 2       # sella aprobación → escribe spec/2-<name>/ (requirements, design, tasks)
#   (sdd:false: approve directo, sin interview/answer)

# Fase 1
node .harness/orchestrator.mjs --dry-run
node .harness/orchestrator.mjs         # implementa, corre gates, escribe progress/
node .harness/spec.mjs done 2          # tras revisar el diff del commit feat(<name>)
```

El agente que implementa: trabaja solo sobre la tarea asignada y dentro del `scope` (+ `docs/`), sin commits
propios, lee `docs/` antes de empezar, y al fallar un gate corrige lo que indica el feedback sin reescribir
todo ni ampliar el scope.

---

## 9. Gates y stack

`init.sh` detecta el stack y escribe `.harness/gates.config.json` (Node/TS, Supabase/Deno, Python, Go, Rust;
o un placeholder con `TODO` si no reconoce nada). Los gates corren en orden de coste y un gate bloqueante que
falla corta la cadena:

```
1. typecheck/compile   2. lint   3. tests   4. diff-scope   [5. LLM-judge opcional, no bloqueante]
```

Si `rules.require_tests_to_close === true`, debe existir un gate de tests. Ajusta `gates.config.json` a mano
si el comando de tests de tu repo difiere.

---

## 10. Métricas

`harness-state.json` registra, por tarea e intento: `tts` (segundos reales), `cost` (solo con Claude; `null`
con Codex), `attempt` y el `verdict` de cada gate. El resumen legible y versionado queda en `progress/`.
Permite calcular de forma reproducible: tiempo medio por feature, éxito al primer intento vs. tras retry,
coste agregado y qué gate falla más.

---

## 11. Límites conocidos

- La confianza autorreportada del modelo es señal débil. El gate real de la entrevista es la **cobertura de dimensiones**; el **pase adversarial** es un aviso para revisar antes de aprobar, no un score.
- El coste por corrida solo se mide con Claude (Codex no lo expone en stdout; habría que parsear el rollout JSONL de la sesión).
- El LLM-as-judge (si lo añades como gate no bloqueante) **no está validado** contra juicio humano. Revisa una muestra de sus veredictos periódicamente.
- `diff-scope` solo sirve si el `scope` está bien acotado. Un scope demasiado amplio lo vuelve inútil.
- La ejecución es secuencial (`one_feature_at_a_time`). Para features que tocan contratos compartidos, secuéncialas: no las apruebes a la vez.
- En modo unattended el agente escribe sin confirmación: aísla la corrida en un `git worktree` o contenedor ⚠️.

---

> **Fuente de verdad del código:** los scripts viven en `.harness/` y se generan desde `init.sh`. Este
> documento describe el sistema y cómo operarlo; no dupliques aquí el código de los `.mjs`.