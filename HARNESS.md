# Harness

Este repo usa un flujo SDD controlado por `.harness/`. Antes de implementar, el agente debe leer este archivo y `docs/`.

## Reglas obligatorias

- El agente del harness es siempre Codex. `HARNESS_AGENT` no cambia el proveedor.
- Si falta `.harness/`, instalarlo con `bash init.sh`.
- No implementar una feature sin `spec_approved: true` en `spec.json`.
- Trabajar una feature cada vez.
- Respetar el `scope` aprobado de la feature. Los gates permiten siempre cambios en `docs/`, `spec/`, `progress/` y `.harness/`.
- No introducir features futuras cuyo spec no este aprobado.
- Mantener `docs/ARCHITECTURE.md`, `docs/CONVENTIONS.md` y `docs/DECISIONS.md` como memoria durable cuando una decision de implementacion lo requiera.

## Flujo SDD

1. Preparar spec:
   - Preferido para "siguiente sprint": `node .harness/spec.mjs prepare <id>`; genera la entrevista, adopta respuestas tÃ©cnicas conservadoras y ejecuta QA hasta `spec_ready`.
   - `node .harness/spec.mjs interview <id>`
   - Responder en `.harness/interviews/<id>-<name>.md`
   - `node .harness/spec.mjs answer <id>`
   - Si procede: `node .harness/spec.mjs force-ready <id>`
2. Aprobar spec:
   - `node .harness/spec.mjs approve <id>`
   - Esto marca `spec_approved: true` y escribe `spec/<id>-<name>/{requirements,design,tasks}.md`.
3. Implementar:
   - Preferido cuando el arbol esta limpio: `node .harness/orchestrator.mjs`
   - Si se implementa manualmente, seguir el spec aprobado, actualizar checklist/progreso y ejecutar todos los gates.
4. Revisar:
   - Una feature SDD implementada queda en `review_pending`.
   - Tras smoke test humano, cerrar con `node .harness/spec.mjs done <id>`.

## Gates

Los gates configurados estan en `.harness/gates.config.json`. En este repo deben pasar:

- `corepack pnpm typecheck`
- `corepack pnpm lint`
- `corepack pnpm test`
- `diff-scope`

Cuando un criterio de aceptacion lo exija, tambien ejecutar explicitamente:

- `corepack pnpm install --frozen-lockfile`

## Progreso

El harness escribe memoria de ejecucion en `progress/`:

- `progress/current.md`: feature actual y siguiente accion.
- `progress/history.md`: historial.
- `progress/impl_<name>.md`: intentos de implementacion.
- `progress/review_<name>.md`: veredicto y checkpoints.

`.harness/harness-state.json` es estado local de maquina y no debe tratarse como documentacion durable.
