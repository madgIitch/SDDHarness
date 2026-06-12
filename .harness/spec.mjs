import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { runAgent, extractJson } from "./runner.mjs";

const SPEC = "spec.json";
const IDIR = ".harness/interviews";

const DIMENSIONS = [
  "data_model", "error_states", "edge_cases", "auth_secrets",
  "external_contracts", "ui_states", "rollback_compat", "tests",
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
  if (f.sdd === false) { console.log(`Feature ${id} es sdd:false → sin entrevista. Apruébala: spec.mjs approve ${id}`); return; }
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
  if (f.sdd !== false) {
    const sc = loadSc(id);
    if (!sc.ready) throw new Error(`Feature ${id}: spec no listo (ready:false).`);
    if (f.status !== "spec_ready") throw new Error(`Feature ${id} debe estar en spec_ready (está en ${f.status}).`);
    f.answers_hash = "sha256:" + createHash("sha256").update(JSON.stringify(sc.answers)).digest("hex");
  }
  f.spec_approved = true; f.approved_by = by; f.approved_at = new Date().toISOString();
  saveSpec(spec);
  console.log(`Feature ${id} aprobada por ${by}.`);
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
