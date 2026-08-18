# Shared smoke-stub argv/stdin capture contract (#164).
# Source this file from a *.smoke.sh, call make_stub_capture_helper to write
# the runtime snippet once per temp dir, and have every $BIN stub source that
# snippet as its first statement. See "Smoke-test stub capture contract" in
# docs/agents/multi-agent-workflow.md for the authoring rules.
#
# make_stub_capture_helper FILE
#   Writes the snippet to FILE. Export FILE as STUB_CAPTURE_HELPER so stub
#   binaries can `. "$STUB_CAPTURE_HELPER"`. The snippet appends the stub's
#   full argv as one "$*" line to $STUB_ARGS_LOG (when set) and appends
#   consumed stdin to $STUB_STDIN_LOG (when set). Stubs that do not consume
#   stdin never drain it: stdin capture is opt-in per case via STUB_STDIN_LOG.
#   Smoke cases grep the capture files for the exact argv/stdin the pipeline
#   was intended to pass, and pair each regression-guard case with a
#   mutation-check case proving the grep rejects a reverted or malformed argv.
make_stub_capture_helper() {
  cat > "$1" <<'EOF'
if [ -n "${STUB_ARGS_LOG:-}" ]; then printf '%s\n' "$*" >> "$STUB_ARGS_LOG"; fi
if [ -n "${STUB_STDIN_LOG:-}" ]; then cat >> "$STUB_STDIN_LOG"; fi
EOF
}
