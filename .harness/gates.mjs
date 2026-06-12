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
