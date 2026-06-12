import { readFileSync, writeFileSync, existsSync } from "node:fs";
const STATE = ".harness/harness-state.json";
export const loadSpec = () => JSON.parse(readFileSync("spec.json", "utf8"));
export const loadState = () => existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : { tasks: {}, startedAt: new Date().toISOString() };
export const saveState = (s) => writeFileSync(STATE, JSON.stringify(s, null, 2));
