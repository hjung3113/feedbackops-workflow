# Live TUI is a separate execution mode with adapter-owned session control

Status: accepted

`execution_mode` is a separate axis from the existing permission `mode`: `headless` remains the default, while phase 1 admits `live-tui` only for an implementation seat with write permission. Runtime members own command policy and emit a shell-free launch spec (`argv[]`, `env`, and `prompt_delivery`); transport adapters own session lifecycle and never interpret runtime-specific flags. This keeps the existing headless runner/watchdog path unchanged and prevents a missing live capability from silently falling back to headless.

## Durable live contract

- D1: launch acknowledgement and liveness evidence is `.review/ISSUE-N-launch.*/LIVE.json`. It records ready and prompt-start activity only, never workflow completion.
- D2: `live-session-supervisor.sh` owns the adapter-neutral sequence `wait-ready -> baseline read -> send -> activity`; its settled and canonical-artifact gate functions cover the later `settled -> artifact-gate` phase.
- D3: the launch spec is argv-shaped. Orca's later adapter implementation may join each token with `printf %q` for its required single command string; naive concatenation is not a valid transport.
- D4: Codex live argv explicitly carries `--ask-for-approval never`.
- D5: selection is only `dispatch-core.sh --execution-mode headless|live-tui` in this phase. No workflow-config or model-allocation key selects it.
- D6: transport receipt schema v4 carries `execution_mode`, structured `handles`, and `launch_spec_sha256`. `external_handle` is optional; `runner` is conditional and required only for `execution_mode=headless`. Live receipts do not perform runner hash checks.
- D7: settled classification is normalized to `settled|working|blocked|stale|terminal`. Orca requires post-send activity plus `tui-idle`; Herdr maps its native states directly; cmux can claim settled only with a help-proven agent-state query, otherwise canonical artifact polling remains authoritative and screen matches are diagnostic.
- D8: phase 1 emits `prompt_delivery: transport` for every runtime. `initial-argv` remains an enum slot but is not admitted.
- D9: live partial-work stashing is limited to adapter-reported abnormal termination or a transport disconnect after activity and before a fresh canonical artifact. Blocked and settled-without-artifact are contract failures, not stash triggers.
- D10: Herdr remains a future write-capable transport implementation; T1 defines the shared seam and does not add an adapter-specific Herdr path or exclude it from the eventual write-dispatch set.
- D11: live timeouts are `LIVE_WAIT_READY_TIMEOUT_MS`, `LIVE_SEND_ACTIVITY_TIMEOUT_MS`, `LIVE_WAIT_SETTLED_TIMEOUT_MS`, and `LIVE_SESSION_TIMEOUT_MS`, defaulting to watchdog-scale 240000, 180000, 180000, and 3600000 milliseconds respectively.

The semantic adapter capabilities are `session.live.launch`, `session.ready.wait`, `session.input.send`, `session.output.read`, `session.activity.observe`, `session.state.wait`, `session.interrupt`, and `session.close`. A transport must prove the complete set before live admission; headless availability is reported separately.

## T5 decision gate: does `execution_mode` default flip? (2026-08-22)

**Decision: no default flip. `execution_mode` stays explicit-opt-in `--execution-mode live-tui` (D5), per-adapter, not global, until each adapter has passed its own real-binary verification pass.**

Rationale, by adapter:

- **cmux**: archived (#208, see HANDOFF.md and `toolkit/STATUS.md`). Real cmux 0.64.x lacks the subcommands the T4 adapter assumed; its live capability already fails closed at the capability-probe stage. Not eligible for any default until #208's rewrite lands and is itself real-binary verified. Out of scope for further work until orca/herdr are stable (see the archive note).

- **orca**: partially real-binary verified this session (2026-08-22, orca 1.4.188, from inside a live Orca terminal). `capabilities --probe-live`, `launch-live`, `wait-ready`, `read`, `wait-settled`, `send`, and stale-handle detection on `wait-ready`/`wait-settled`/`send` (#206's fix) all behaved correctly against the real binary. However this same pass found a **new, unfixed real-binary defect**: `read` never inspects the closed-terminal `status:"exited"` field real Orca returns on a zero-exit response, so reading a dead handle silently returns `{"output":"","cursor":"0"}` instead of a stale signal (filed as #210, not fixed here per policy — toolkit defects get filed, not unilaterally patched). Orca is not eligible for a default flip until #210 lands and is itself real-binary re-verified.

- **herdr**: real-binary verified 2026-08-22 (herdr 0.8.0, from inside a live Herdr session, real omp/glm-5.3 agent). `capabilities --probe-live` correctly stays headless-only (fail-closed). `read`, `send` (happy path), `inspect`, and stale-handle detection on `read`/`send`/`inspect` after a real workspace close all behaved correctly — no #210-equivalent silent-success bug found here. This pass found **two new, unfixed real-binary defects**, both filed, neither fixed here per policy: **#211** — `parse_agent_state` reads the wrong JSON field (`.result.agent.status` instead of real herdr's `.result.agent.agent_status`), so `wait_ready` and `wait_settled` always fail even against a genuinely idle agent; **#212** — the trust-prompt-blocked-launch acceptance test can never pass as constructed (shell command-echo breaks the `\A`-anchored detection rule), and real `agent start` against the same blocked scenario just times out and loses the agent entirely rather than reaching a `blocked` state, so herdr's live launch path has no proven way to survive a first-run trust prompt. Herdr is not eligible for a default flip until #211 and #212 both land and are themselves real-binary re-verified.

**Net**: no adapter currently qualifies for a default-flip. Revisit this gate per-adapter as each one passes its own real-binary pass with no open defects (cmux: also needs #208 first). Do not flip the global default or move any adapter's default independently of this gate — this record is the authority per D5, supersedes prose in stale handoff files.
