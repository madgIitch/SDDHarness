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
