#!/usr/bin/env node
const fs = require("fs");
const [roundState, admissionKey] = process.argv.slice(2);
if (!roundState || !admissionKey) process.exit(2);
if (process.env.AGENT_WORKFLOW_ADMISSION_ADVANCE_FAIL === "1") process.exit(2);
const match = /^issue-[0-9]+-dispatch-([0-9]+)$/.exec(admissionKey);
if (!match) process.exit(2);
try {
  const state = JSON.parse(fs.readFileSync(roundState, "utf8"));
  state.round_control = state.round_control || { failures: [] };
  const ordinal = Number(match[1]);
  const current = Number.isInteger(state.round_control.next_dispatch_ordinal)
    ? state.round_control.next_dispatch_ordinal : 1;
  // The gate selected the one next ordinal. Never let this persistence helper
  // turn a forged/skipped key into a jump over circuit-breaker evidence.
  if (ordinal !== current) process.exit(2);
  state.round_control.next_dispatch_ordinal = ordinal + 1;
  state.round_control.last_admission_key = admissionKey;
  if (state.round_control.blocker_recovery && state.round_control.blocker_recovery.status === "ready") {
    state.round_control.blocker_recovery.status = "used";
  }
  const temp = `${roundState}.tmp.${process.pid}`;
  fs.writeFileSync(temp, JSON.stringify(state, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  fs.renameSync(temp, roundState);
} catch (_) {
  process.exit(2);
}
