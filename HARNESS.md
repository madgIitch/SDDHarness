# Harness

Este repo usa un flujo SDD controlado por `.harness/`. Antes de implementar, el agente debe leer este archivo y `docs/`.

## Reglas obligatorias

- El agente de la sesión (el que lee este archivo) es quien entrevista, redacta el spec e implementa. El harness **no lanza ningún LLM**: solo guarda estado, ejecuta gates y escribe memoria. No hay proveedor ni modelo fijados en `.harness/`.
- Si falta `.harness/`, instalarlo con `bash init.sh`.
- No implementar una feature sin `spec_approved: true` en `spec.json`.
- La aprobación (`approve`) la decide el dev. El agente nunca la ejecuta ni usa `force-ready` por su cuenta.
- Trabajar una feature cada vez.
- Respetar el `scope` aprobado de la feature. Los gates permiten siempre cambios en `docs/`, `spec/`, `progress/` y `.harness/`.
- No introducir features futuras cuyo spec no esté aprobado.
- Mantener `docs/ARCHITECTURE.md`, `docs/CONVENTIONS.md` y `docs/DECISIONS.md` como memoria durable cuando una decisión de implementación lo requiera.

## Flujo SDD

1. Preparar spec (el agente conduce, el dev decide):
   - `node .harness/spec.mjs interview <id>` crea la plantilla `.harness/interviews/<id>-<name>.md` (8 dimensiones, scope y acceptance de partida). No usa IA.
   - El agente lee `docs/` y el código, y rellena la entrevista: pregunta concreta por dimensión abierta, `**R:**` con las respuestas del dev (o decisiones conservadoras que el dev confirma), dimensiones cubiertas en ✅, `Scope propuesto` y `Acceptance propuesto` testables.
   - Repaso adversarial antes de cerrar: el agente lista ambigüedades bloqueantes del acceptance (umbrales sin definir, rutas o campos sin especificar, comportamientos donde dos implementaciones razonables difieren) y las resuelve o las anota como suposiciones.
   - `node .harness/spec.mjs answer <id>` valida la entrevista (determinista): si las 8 dimensiones están cubiertas y hay scope y acceptance, la feature pasa a `spec_ready`.
   - `node .harness/spec.mjs force-ready <id>` solo por decisión explícita del dev.
2. Aprobar spec (dev):
   - `node .harness/spec.mjs approve <id>` marca `spec_approved: true` y escribe `spec/<id>-<name>/{requirements,design,tasks}.md`.
3. Implementar (en la sesión):
   - El agente implementa siguiendo `spec/<id>-<name>/`, marca `tasks.md` y escribe tests.
   - Cierre: `node .harness/orchestrator.mjs --verify <id>`. Ejecuta los gates, y si pasan commitea `feat(<name>)`, escribe `progress/` y deja la feature en `review_pending`. Si fallan, imprime el gate y no cambia el estado: se corrige y se repite.
   - Opcional, desatendido: con `HARNESS_AGENT_CMD` apuntando a un CLI que lea el prompt por stdin, `node .harness/orchestrator.mjs` implementa la cola entera con reintentos (árbol limpio). Es un modo secundario.
4. Revisar:
   - Una feature SDD implementada queda en `review_pending`.
   - Tras smoke test humano, cerrar con `node .harness/spec.mjs done <id>`.

## Apartar una feature (`shelved`)

Cuando el dev decide que un sprint no merece hacerse ahora (poca demanda, riesgo, cambio de rumbo), se aparta en lugar de borrarlo:

- `node .harness/spec.mjs shelve <id> "motivo"` (el motivo es obligatorio, mínimo 10 caracteres). Solo admite features en `pending`, `spec_ready` o `blocked`: una feature ya implementada (`review_pending`) se cierra con `done` o se revierte con `git revert`, no se aparta.
- Queda con `status: "shelved"`, `shelved_at`, `shelved_reason` y `shelved_from`. Sale de la cola del orquestador y de los avisos de aprobación, pero conserva su entrevista y su spec. El orquestador en seco (`--dry-run`) las lista aparte.
- Si otras features vivas dependen de ella, el comando lo avisa para que el dev decida si también se apartan.
- `node .harness/spec.mjs unshelve <id>` la reactiva en el estado en que estaba (`spec_ready` si estaba `blocked`).
- El agente solo aparta o reactiva cuando el dev lo pide. Una feature apartada no se propone ni se implementa. Conviene dejar el motivo también en `docs/DECISIONS.md`.

## Posponer una feature (`postponed`)

Cuando el spec es bueno pero **hoy no hace falta**, y se sabe qué señal dirá «ahora sí», se pospone en lugar de apartarla. La diferencia con `shelved`: apartar es «no se va a hacer ahora», sin más; posponer es «se hará cuando pase esto», y ese **disparador** es obligatorio.

- `node .harness/spec.mjs postpone <id> "disparador"`: lo observable que reactivará la feature (un fallo que se repite, un número que se supera, una petición concreta). Mínimo 10 caracteres; sin disparador no se pospone, se aparta. Admite `pending`, `spec_ready` o `blocked`; una feature implementada se cierra con `done` o se revierte con `git revert`.
- Queda con `status: "postponed"`, `postponed_at`, `postponed_trigger` y `postponed_from`. **Conserva su entrevista, su spec y su aprobación** (`spec_approved` no cambia). Sale de la cola del orquestador, que no la toma aunque esté aprobada.
- El orquestador en seco (`--dry-run`) las lista aparte **con su disparador**, para que no se olviden: «Pospuestas (postponed, fuera de la cola, esperan su disparador)».
- Si otras features vivas dependen de ella, el comando lo avisa; no podrán avanzar mientras esté pospuesta.
- `node .harness/spec.mjs unpostpone <id>` la reactiva en el estado en que estaba (`spec_ready` si estaba `blocked`).
- `answer` y `force-ready` se niegan sobre una feature pospuesta (y apartada): reactivarla es una decisión explícita, no un efecto de seguir con su entrevista.
- El agente solo pospone o reactiva cuando el dev lo pide. Una feature pospuesta no se propone ni se implementa; cuando el agente vea cumplido el disparador, **avisa al dev** en lugar de reactivarla por su cuenta. Conviene dejar la decisión también en `docs/DECISIONS.md`.

## Gates

Los gates configurados estan en `.harness/gates.config.json`. En este repo deben pasar:

- `corepack pnpm typecheck`
- `corepack pnpm lint`
- `corepack pnpm test`
- `diff-scope`

Si un gate falla, el mensaje de `--verify` muestra las líneas de fallo (tests, aserciones, errores de tsc o eslint, archivos fuera de scope) y el final de la salida. La salida completa queda en `.harness/logs/<feature>-<gate>.log`, que no se versiona y se sobrescribe en cada intento.

Cuando un criterio de aceptacion lo exija, tambien ejecutar explicitamente:

- `corepack pnpm install --frozen-lockfile`

## Progreso

El harness escribe memoria de ejecucion en `progress/`:

- `progress/current.md`: feature actual y siguiente accion.
- `progress/history.md`: historial.
- `progress/impl_<name>.md`: intentos de implementacion.
- `progress/review_<name>.md`: veredicto y checkpoints.

`.harness/harness-state.json` es estado local de maquina y no debe tratarse como documentacion durable.

## Ramas

- Se trabaja siempre en `main`. Nunca crear ni usar ramas, worktrees ni pull requests de feature.
- Commitea directamente en `main` y haz `git push origin main`.
- Si te encuentras en otra rama, vuelve a `main` antes de tocar nada.
