# Cambios encontrados y justificación

Este documento resume los problemas detectados durante la corrida del harness en un proyecto generado desde esta base, y explica por qué se proponen los cambios aplicados a `init.sh` y `HARNESS.md`.

## Problemas encontrados

1. `scope` y `acceptance` no siempre llegan como arrays
   - En la corrida, el agente devolvió `scope` como string en lugar de array.
   - El renderer hacía `(res.scope || []).map(...)`, lo que provocó `TypeError: (res.scope || []).map is not a function`.
   - Riesgo: cualquier respuesta válida pero no estrictamente tipada del LLM rompe el flujo SDD.

2. Las suposiciones adversariales podían imprimirse como `[object Object]`
   - El pase adversarial devolvió objetos en vez de strings.
   - El harness los imprimía directamente, generando mensajes inútiles como `el implementador adivinaría: [object Object]`.
   - Riesgo: el dev no puede responder una ambigüedad si el texto real se pierde.

3. Las claves `adv1`, `adv2`, etc. mezclaban respuestas entre rondas
   - El pase adversarial cambia de orden o reemplaza preguntas en cada ejecución.
   - Si una pregunta nueva ocupa `adv1`, puede heredar la respuesta vieja de otra pregunta distinta.
   - Riesgo: el spec incorpora respuestas incorrectas y entra en ciclos de aclaraciones falsas.

4. El LLM regeneraba criterios de aceptación ya estabilizados
   - Cada `answer` podía reescribir los criterios de aceptación con nuevas frases ambiguas.
   - El pase adversarial encontraba nuevas ambigüedades en criterios que antes ya estaban resueltos.
   - Riesgo: la Fase 0 no converge aunque el dev ya haya dado suficiente información.

5. Los criterios se podían partir incorrectamente por comas
   - La normalización anterior separaba strings con `/\n|,/`.
   - Un criterio largo con comas podía convertirse en varios criterios incompletos.
   - Riesgo: se destruye la semántica de los ACs y se generan nuevas ambigüedades artificiales.

6. Las dimensiones omitidas por el agente deben seguir bloqueando
   - Si el agente no devuelve una dimensión, el harness debe tratarla como no cubierta.
   - Esto mantiene el objetivo SDD: no implementar sin cubrir data model, errores, edge cases, contratos, UI, rollback y tests.

7. El dev necesita una salida manual cuando Fase 0 no converge
   - Algunas ambigüedades detectadas por el pase adversarial pueden ser demasiado finas o aceptables para avanzar.
   - Si el dev ya revisó el Markdown y decide asumir el riesgo, el harness debe permitir pasar a `spec_ready` sin pelearse con el modelo.
   - Riesgo si no existe esta salida: el proceso queda bloqueado por criterio del LLM aunque el responsable humano ya haya tomado una decisión.

## Cambios propuestos

1. Normalización defensiva de listas
   - `scope` y `acceptance` se normalizan con una función común.
   - Se aceptan arrays o strings multilinea.
   - No se separa por comas, porque las comas son contenido válido dentro de un criterio.

2. Normalización defensiva de `guesses`
   - Si el pase adversarial devuelve strings, se usan directamente.
   - Si devuelve objetos, se extraen campos útiles como `question`, `point`, `text` o `reason`.
   - Si no hay campos conocidos, se usa `JSON.stringify` para no perder información.

3. Claves estables para suposiciones adversariales
   - En lugar de `adv1`, `adv2`, etc., se genera una clave derivada del texto.
   - Así una respuesta solo se reutiliza si la pregunta es efectivamente la misma.

4. Preservar `Scope propuesto` y `Acceptance propuesto`
   - `answer` parsea las secciones existentes del Markdown de entrevista.
   - Si ya existen, las conserva y las pasa al agente como contexto.
   - Esto evita que el LLM regenere criterios ya estabilizados y reduzca la convergencia.

5. Mantener la semántica actual del harness
   - La readiness (`spec_ready`) sigue dependiendo de cubrir las 8 dimensiones.
   - El pase adversarial queda como aviso revisable antes de aprobar, no como bloqueo infinito.
   - Esta decisión evita que el harness quede atrapado en aclaraciones cada vez más granulares.

6. Documentar el comportamiento en `HARNESS.md`
   - Se añade una explicación explícita de la preservación de AC/scope.
   - Se documenta que las suposiciones adversariales tienen claves estables.
   - Se aclara que las salidas no estrictamente tipadas del agente se normalizan antes de renderizarse.

7. Añadir `force-ready`
   - Nueva orden: `node .harness/spec.mjs force-ready <id>`.
   - Toma el `Scope propuesto` y el `Acceptance propuesto` actuales del Markdown de entrevista.
   - Marca la feature como `spec_ready` con metadatos de override manual.
   - No aprueba ni implementa: mantiene el paso humano posterior de `approve`.

## Resultado esperado

- La Fase 0 deja de romperse por variaciones normales de salida del LLM.
- El Markdown de entrevista sigue siendo editable y estable entre rondas.
- El dev puede revisar suposiciones adversariales sin que bloqueen indefinidamente.
- Si el modelo no converge, el dev puede avanzar explícitamente con `force-ready` sin saltarse la aprobación.
- Los specs aprobados salen de una base más fiable y menos propensa a ciclos artificiales.
