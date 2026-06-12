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
  }
}

function record(state, id, entry) { state.tasks[id] ??= { attempts: [] }; state.tasks[id].attempts.push(entry); }
main().catch((e) => { console.error("Harness error:", e); process.exit(1); });
