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
