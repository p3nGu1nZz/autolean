#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

STATE_DIR="${PROJECT_ROOT}/data/copilot"
HISTORY_DIR="${STATE_DIR}/autolean.sh_history"
SHARE_OUTPUT="${STATE_DIR}/lean_update_output.md"
LEGACY_SHARE_OUTPUT="${STATE_DIR}/lean_update.md"
PROMPT_FILE="${STATE_DIR}/autolean.sh_prompt.md"
FINAL_SUMMARY="${STATE_DIR}/autolean.sh_final_summary.md"
RUN_LOG="${STATE_DIR}/autolean.sh_loop.log"

MAX_PREVIOUS_OUTPUT_BYTES="${AUTO_LEAN_MAX_PREVIOUS_OUTPUT_BYTES:-12000}"
MAX_SHARE_LINES="${AUTO_LEAN_MAX_SHARE_LINES:-120}"
MAX_HISTORY_FILES="${AUTO_LEAN_MAX_HISTORY_FILES:-40}"
ITERATION_COOLDOWN_SECONDS="${AUTO_LEAN_ITERATION_COOLDOWN_SECONDS:-${AUTO_LEAN_SLEEP_SECONDS:-300}}"
RETRY_COOLDOWN_SECONDS="${AUTO_LEAN_RETRY_COOLDOWN_SECONDS:-60}"

ITERATION=0
LAST_STATUS="continue"
LAST_REASON="No iterations have completed yet."
REQUIRED_MODEL="gpt-5.1-codex-mini"

print_info() {
  printf '[autolean.sh] %s\n' "$1"
}

cooldown() {
  local seconds="$1" reason="$2"
  print_info "${reason} Waiting ${seconds}s."
  sleep "$seconds"
}

copy_exec() {
  cp -p "$1" "$2"
  chmod +x "$2" || true
}

sync_shared_output() {
  cp "$SHARE_OUTPUT" "$LEGACY_SHARE_OUTPUT"
}

file_contains_required_model() {
  local f="$1"
  grep -Eq -- "^REQUIRED_MODEL=\"${REQUIRED_MODEL}\"$" "$f" 2>/dev/null \
    && grep -Eq -- "--model[[:space:]]+(\"\\\$REQUIRED_MODEL\"|\"?${REQUIRED_MODEL}\"?)" "$f" 2>/dev/null
}

ensure_file_model() {
  local f="$1"
  if command -v sed >/dev/null 2>&1; then
    sed -E -i "s/^REQUIRED_MODEL=.*/REQUIRED_MODEL=\"${REQUIRED_MODEL}\"/" "$f" 2>/dev/null || true
    sed -E -i "s/--model([[:space:]]+)(\"[^\"]+\"|'[^']+'|[^[:space:]]+)/--model \"${REQUIRED_MODEL}\"/g" "$f" 2>/dev/null || true
  fi
  if ! file_contains_required_model "$f"; then
    printf '\nREQUIRED_MODEL="%s"\n' "$REQUIRED_MODEL" >> "$f"
  fi
}

# PID file to prevent multiple controllers
PIDFILE="${STATE_DIR}/autolean.sh.pid"

check_controller_running() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      print_info "Controller already running (pid $pid). Exiting."
      exit 0
    else
      rm -f "$PIDFILE" 2>/dev/null || true
    fi
  fi
}

write_pidfile() {
  printf '%s' "$$" > "$PIDFILE" 2>/dev/null || true
}

compute_hash() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$file" | awk '{print $1}'
  else
    # Fallback: use file mtime/size as a cheap fingerprint
    stat -c '%Y-%s' "$file" 2>/dev/null || true
  fi
}

ensure_state_dirs() {
  mkdir -p "$STATE_DIR" "$HISTORY_DIR"
  touch "$RUN_LOG"
}

bootstrap_shared_output() {
  if [[ -f "$SHARE_OUTPUT" ]]; then
    return 0
  fi

  cat > "$SHARE_OUTPUT" <<'EOF'
# Auto Lean Iteration Report
## Summary
- Bootstrap state created. No prior Copilot iteration output exists yet.
## Evidence
- Awaiting first autonomous pass.
- Five paper-linked modules are in scope: HFSMFoundation, Level2Physics, Level3PhysicsSystem, RLFramework, SingletonLaw.
## Files Changed
- None yet.
## Next Opportunities
- Run ./scripts/lean.sh status if toolchain state is unknown.
- Begin targeted checks on the paper-linked modules and inspect the linked LaTeX sources when theorem coverage changes.
AUTO_LEAN_STATUS: continue
AUTO_LEAN_REASON: Bootstrap state only; no work has been attempted yet.
AUTO_LEAN_NEXT: Check toolchain status and begin auditing the paper-linked modules.
EOF

  sync_shared_output
}

shared_output_has_contract() {
  [[ -f "$SHARE_OUTPUT" ]] \
    && grep -q '^AUTO_LEAN_STATUS:' "$SHARE_OUTPUT" \
    && grep -q '^AUTO_LEAN_REASON:' "$SHARE_OUTPUT" \
    && grep -q '^AUTO_LEAN_NEXT:' "$SHARE_OUTPUT"
}

repair_shared_output_if_needed() {
  if [[ ! -f "$SHARE_OUTPUT" ]] || shared_output_has_contract; then
    return 0
  fi

  local recovered_excerpt
  recovered_excerpt="$(tail -n 12 "$SHARE_OUTPUT" | sed 's/^/- recovered: /')"

  cat > "$SHARE_OUTPUT" <<EOF
# Auto Lean Iteration Report
## Summary
- Recovered a malformed shared report that did not follow the loop footer contract.
- Preserved a bounded tail excerpt below so the next iteration still sees the latest evidence.
## Evidence
${recovered_excerpt}
## Files Changed
- scripts/copilot/autolean.sh: repaired malformed shared-report state so the next iteration can overwrite it cleanly.
## Next Opportunities
- Continue iterating and replace this recovery stub with a normal concise report.
AUTO_LEAN_STATUS: continue
AUTO_LEAN_REASON: Recovered malformed shared report into the expected loop format.
AUTO_LEAN_NEXT: Continue iterating and overwrite this recovered placeholder with a normal concise report.
EOF

  sync_shared_output
}

read_previous_output_excerpt() {
  if [[ ! -f "$SHARE_OUTPUT" ]]; then
    printf 'No previous shared output is available yet.\n'
    return 0
  fi

  tail -c "$MAX_PREVIOUS_OUTPUT_BYTES" "$SHARE_OUTPUT"
}

build_prompt() {
  local previous_output
  previous_output="$(read_previous_output_excerpt)"

  cat > "$PROMPT_FILE" <<EOF
You are continuing an autonomous Lean proof-maintenance loop.
Operate in one bounded iteration, but think autoregressively: use the previous shared report as durable memory, improve the repository, write the next concise report, and let the outer shell loop decide whether to continue.

Goals:
- Search/use ./data/copilot/lean_update_output.md before deciding what to do.
- Reuse it to find proof failures, elaboration errors, theorem-coverage gaps, missing mathematician-facing documentation, paper-sync mismatches, and ways to improve scripts/copilot/autolean.sh itself.
- Maximize session token context by summarizing relevant prior work, quoting key evidence from the shared report, and keeping the agent's edit session focused on a coherent proof seam in one go.
- Improve Lean proofs and linked paper exposition meaningfully; avoid low-value churn.
- Keep changes small, verifiable, and maintainable.

Paper-linked scope:
- tools/lean/CatGameProofs/HFSMFoundation.lean ↔ docs/research/papers/hfsm_mathematical_foundation/main.tex
- tools/lean/CatGameProofs/Level2Physics.lean ↔ docs/research/papers/level_2_physics_proof/main.tex
- tools/lean/CatGameProofs/Level3PhysicsSystem.lean ↔ docs/research/papers/level_3_physic_system/main.tex
- tools/lean/CatGameProofs/RLFramework.lean ↔ docs/research/papers/rl_framework_for_ai_agents_in_game_systems/main.tex
- tools/lean/CatGameProofs/SingletonLaw.lean ↔ docs/research/papers/formalized_singleton_law_proof/main.tex

Lean workflow expectations:
- Run from repo root.
- Always use ./scripts/lean.sh as the canonical entrypoint when the wrapper can do the job.
- Do not prefer raw lake or raw lean when ./scripts/lean.sh is sufficient.
- If you are unsure whether the Lean toolchain or workspace is provisioned, run ./scripts/lean.sh status first.
- Use targeted checks like ./scripts/lean.sh check CatGameProofs/RLFramework.lean while iterating.
- Use ./scripts/lean.sh build as the canonical full-workspace validation step after meaningful proof edits.
- Use ./scripts/lean.sh test when it adds relevant confidence for proof-workspace health.

Proof sequencing expectations:
- When one module or theorem family is addressed, continue to work through as many high-value nearby opportunities as the session's context allows before wrapping up the iteration.
- Stay within the same proof seam until you either exhaust it or the shared report shows a higher-value adjacent seam.
- Prefer proof work that improves correctness, completeness, readability, and paper alignment over cosmetic refactors.

Paper-facing proof standards:
- Keep theorem names stable when possible so LaTeX references remain accurate.
- Prefer mathematician-facing theorem names and documentation comments.
- Restate key equations, symbols, and invariants in comments when it materially helps a mathematician understand what the Lean declaration proves.
- Keep paper exposition in English math language; do not dump raw Lean code into the paper unless the paper explicitly wants code.
- When theorem coverage, naming, or paper-facing claims change, update the linked LaTeX exposition accordingly.
- Prefer one synthesized mechanization section in the paper, with optional section-local theorem callouts, instead of scattering raw code listings.

Modularization guidance:
- For a growing proof corpus like RLFramework.lean, consider a hybrid structure under tools/lean/CatGameProofs/RLFramework/ such as Returns.lean, PPO.lean, Gradient.lean, Bellman.lean, GAEReplay.lean, Reduction.lean, and Memory.lean.
- If modularization is beneficial, keep tools/lean/CatGameProofs/RLFramework.lean as the barrel entry module that imports the pieces.
- Preserve theorem names within the same namespace when possible so paper references do not churn.

Self-edit rules:
- Read/search ./data/copilot/lean_update_output.md and use it as iteration memory.
- If the previous report or current evidence shows scripts/copilot/autolean.sh can be improved, improve it.
- If you edit scripts/copilot/autolean.sh, compact it before finishing: remove redundant blank lines, collapse non-essential comment blocks, prefer existing helpers/structure over new layers, and verify with bash -n scripts/copilot/autolean.sh.
- Edits to scripts/copilot/autolean.sh only take effect on the next manual launch of the shell script, not retroactively in the current process.
- After meaningful Lean or paper-facing changes, run the relevant canonical verification with ./scripts/lean.sh check ... and ./scripts/lean.sh build.
- If verification fails, fix it before ending this iteration.
- If a paper-linked Lean file changes and a trustworthy paper rebuild path is practical without guessing unsupported commands, validate it; otherwise keep the LaTeX source aligned and explicitly report any unvalidated paper-build gap.

Stopping rule:
- Set AUTO_LEAN_STATUS: done only if meaningful proof-maintenance opportunities appear exhausted, relevant verification is clean, linked paper exposition is aligned with the formalization, and no realistic near-term improvement remains without speculative or low-value churn.
- Otherwise set AUTO_LEAN_STATUS: continue.

Shared report contract:
- Overwrite ./data/copilot/lean_update_output.md directly with the concise report for this iteration.
- Do not rely on transcript sharing or append a session export; the shell loop parses this file as plain report data.
- Keep the report bounded to at most ${MAX_SHARE_LINES} lines.
- Use exactly this footer:
  AUTO_LEAN_STATUS: continue|done
  AUTO_LEAN_REASON: <single line>
  AUTO_LEAN_NEXT: <single line>

Recommended report shape:
# Auto Lean Iteration Report
## Summary
- brief bullets
## Evidence
- proof checks, build output, code paths, theorem coverage, and paper sections reviewed
## Files Changed
- files and purpose
## Next Opportunities
- remaining high-value proof work, or "None"
AUTO_LEAN_STATUS: continue|done
AUTO_LEAN_REASON: <single line>
AUTO_LEAN_NEXT: <single line>
Previous shared report excerpt (truncated to ${MAX_PREVIOUS_OUTPUT_BYTES} bytes):
---
${previous_output}
---
EOF
}

trim_shared_output() {
  if [[ ! -f "$SHARE_OUTPUT" ]]; then
    return 0
  fi

  local total_lines
  total_lines=$(wc -l < "$SHARE_OUTPUT")
  if [[ "$total_lines" -le "$MAX_SHARE_LINES" ]]; then
    sync_shared_output
    return 0
  fi

  local keep_tail=12
  local inserted_lines=3
  local keep_head=$((MAX_SHARE_LINES - keep_tail - inserted_lines))
  if [[ "$keep_head" -lt 20 ]]; then
    keep_head=20
  fi

  {
    head -n "$keep_head" "$SHARE_OUTPUT"
    printf '\n[autolean.sh truncated this report to keep it bounded.]\n\n'
    tail -n "$keep_tail" "$SHARE_OUTPUT"
  } > "${SHARE_OUTPUT}.tmp"

  mv "${SHARE_OUTPUT}.tmp" "$SHARE_OUTPUT"
  sync_shared_output
}

extract_status_field() {
  local field_name="$1"
  local default_value="$2"

  if [[ ! -f "$SHARE_OUTPUT" ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  local value
  value=$(grep -E "^${field_name}:" "$SHARE_OUTPUT" | tail -n 1 | sed -E "s/^${field_name}:\s*//" || true)
  if [[ -z "$value" ]]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  printf '%s\n' "$value"
}

archive_iteration_output() {
  local archive_file
  archive_file="${HISTORY_DIR}/iteration_$(printf '%04d' "$ITERATION").md"
  cp "$SHARE_OUTPUT" "$archive_file"

  local archived_count
  archived_count=$(find "$HISTORY_DIR" -maxdepth 1 -type f -name 'iteration_*.md' | wc -l)
  if [[ "$archived_count" -le "$MAX_HISTORY_FILES" ]]; then
    return 0
  fi

  local delete_count=$((archived_count - MAX_HISTORY_FILES))
  find "$HISTORY_DIR" -maxdepth 1 -type f -name 'iteration_*.md' | sort | sed -n "1,${delete_count}p" | while read -r old_file; do
    rm -f "$old_file"
  done
}

record_iteration_log() {
  local next_action="$1"
  printf '%s\titeration=%s\tstatus=%s\treason=%s\tnext=%s\n' \
    "$(date -Iseconds)" \
    "$ITERATION" \
    "$LAST_STATUS" \
    "$LAST_REASON" \
    "$next_action" >> "$RUN_LOG"
}

run_iteration() {
  ITERATION=$((ITERATION + 1))
  print_info "Starting iteration ${ITERATION}."

  repair_shared_output_if_needed
  build_prompt

  # The agent updates SHARE_OUTPUT directly. Avoid --share here because it writes a
  # full Copilot session transcript, which breaks the loop's concise report parsing.
  if ! copilot \
    --prompt="$(cat "$PROMPT_FILE")" \
    --model "$REQUIRED_MODEL" \
    --allow-all-paths \
    --allow-all-tools \
    --autopilot \
    --no-ask-user \
    --enable-all-github-mcp-tools \
    --reasoning-effort high \
    --plain-diff \
    --no-color \
    --disallow-temp-dir; then
    LAST_STATUS="continue"
    LAST_REASON="Copilot invocation failed; retrying after a short pause."
    record_iteration_log "Retry the loop."
    print_info "$LAST_REASON"
    return 4
  fi

  trim_shared_output
  archive_iteration_output

  LAST_STATUS="$(extract_status_field 'AUTO_LEAN_STATUS' 'continue')"
  LAST_REASON="$(extract_status_field 'AUTO_LEAN_REASON' 'No reason provided.')"
  local next_action
  next_action="$(extract_status_field 'AUTO_LEAN_NEXT' 'Continue iterating.')"

  record_iteration_log "$next_action"
  print_info "Iteration ${ITERATION} completed with status: ${LAST_STATUS}."
  print_info "Reason: ${LAST_REASON}"

  if [[ "$LAST_STATUS" == "done" ]]; then
    cp "$SHARE_OUTPUT" "$FINAL_SUMMARY"
    print_info "Completion detected. Final summary: ${FINAL_SUMMARY}"
    print_info "Shared report: ${SHARE_OUTPUT}"
    return 1
  fi
  return 0
}

print_exit_summary() {
  local exit_code=$?
  trap - EXIT

  if [[ -f "$SHARE_OUTPUT" ]]; then
    cp "$SHARE_OUTPUT" "$FINAL_SUMMARY" 2>/dev/null || true
  fi

  print_info "Exiting autolean.sh loop with code ${exit_code}."
  print_info "Iterations completed: ${ITERATION}"
  print_info "Last status: ${LAST_STATUS}"
  print_info "Last reason: ${LAST_REASON}"
  print_info "Latest shared report: ${SHARE_OUTPUT}"
  print_info "Final summary: ${FINAL_SUMMARY}"
  print_info "Loop log: ${RUN_LOG}"

  # Clean up pidfile if we own it
  if [[ -f "$PIDFILE" && "$(cat "$PIDFILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$PIDFILE" 2>/dev/null || true
  fi

  exit "$exit_code"
}

handle_interrupt() {
  LAST_STATUS="interrupted"
  LAST_REASON="Loop interrupted by user or signal."
  exit 130
}

SCRIPT_FILE="$(readlink -f "${BASH_SOURCE[0]}")"
STABLE_SCRIPT="${STATE_DIR}/autolean.sh_stable.sh"
PREV_SCRIPT="${STATE_DIR}/autolean.sh_prev.sh"
STABLE_HASH_FILE="${STATE_DIR}/autolean.sh_stable.hash"

print_help() {
  cat <<EOF
Usage: autolean.sh [OPTIONS]

Options:
  -h, --help        Show this help message and exit.
  --child,--worker  Run a single child iteration and exit (worker mode).
  --status          Print controller status (paths, stable hash) and exit.

Environment variables (optional):
  AUTO_LEAN_MAX_PREVIOUS_OUTPUT_BYTES   Bytes of previous shared output to include (default 12000)
  AUTO_LEAN_MAX_SHARE_LINES             Max lines to keep in shared report (default 120)
  AUTO_LEAN_MAX_HISTORY_FILES           Max archived iteration files to keep (default 40)
  AUTO_LEAN_ITERATION_COOLDOWN_SECONDS  Seconds to wait after each successful iteration (default 300)
  AUTO_LEAN_RETRY_COOLDOWN_SECONDS      Seconds to wait before retrying after a failed iteration (default 60)
  AUTO_LEAN_SLEEP_SECONDS               Legacy alias for iteration cooldown if the new variable is unset

This script runs a controller that spawns a child worker for each iteration so
edits to the on-disk script take effect on the next cycle. Use --child to run
one iteration manually for debugging.
Enforced model: gpt-5.1-codex-mini
Single-instance: the controller uses ${STATE_DIR}/autolean.sh.pid and exits if another controller is already running.
EOF
}

print_status() {
  echo "Shared report: $SHARE_OUTPUT"
  echo "Stable script: $STABLE_SCRIPT"
  echo "Previous script: $PREV_SCRIPT"
  echo "PID file: $PIDFILE"
  echo "Run log: $RUN_LOG"
  echo "Iteration cooldown: ${ITERATION_COOLDOWN_SECONDS}s"
  echo "Retry cooldown: ${RETRY_COOLDOWN_SECONDS}s"
  if [[ -f "$STABLE_HASH_FILE" ]]; then
    echo "Stable hash: $(cat "$STABLE_HASH_FILE")"
  else
    echo "Stable hash: (none)"
  fi
  if [[ -f "$RUN_LOG" ]]; then
    echo "Last 10 log lines:"; tail -n 10 "$RUN_LOG" || true
  fi
}

# Quick CLI handling for help/status before entering controller/child logic
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi
if [[ "${1:-}" == "--status" ]]; then
  ensure_state_dirs
  print_status
  exit 0
fi

if [[ "${1:-}" == "--kill" ]]; then
  ensure_state_dirs
  # Kill all running autolean.sh processes matching this script path
  script_path="$(readlink -f "${BASH_SOURCE[0]}")"
  pids="$(pgrep -f "$script_path" || true)"
  if [[ -z "$pids" ]]; then
    echo "No autolean.sh processes found."
    exit 0
  fi
  echo "Killing autolean.sh pids: $pids"
  kill $pids 2>/dev/null || true
  rm -f "$PIDFILE" 2>/dev/null || true
  exit 0
fi

# Child/worker mode: run a single iteration and exit with a machine-meaningful code
# Exit codes:
#   0 = success (continue)
#   2 = finished (AUTO_LEAN_STATUS: done)
#  >2 = script/runtime error (controller should rollback)
if [[ "${1:-}" == "--child" || "${1:-}" == "--worker" ]]; then
  ensure_state_dirs
  run_iteration; ret=$?
  [[ $ret -eq 1 ]] && exit 2
  exit "$ret"
fi

# Controller mode: spawn child processes that execute the (possibly-updated) on-disk
# script so changes take effect between iterations. Maintain a stable copy and one
# previous copy for rollback if the newer script fails.
trap print_exit_summary EXIT
trap handle_interrupt INT TERM

ensure_state_dirs
bootstrap_shared_output
check_controller_running
write_pidfile

if [[ ! -f "$STABLE_SCRIPT" ]]; then
  copy_exec "$SCRIPT_FILE" "$STABLE_SCRIPT"
  ensure_file_model "$STABLE_SCRIPT"
  compute_hash "$STABLE_SCRIPT" > "$STABLE_HASH_FILE" 2>/dev/null || true
fi
if [[ ! -f "$PREV_SCRIPT" ]]; then
  copy_exec "$STABLE_SCRIPT" "$PREV_SCRIPT"
fi

print_info "Repo root: ${PROJECT_ROOT}"
print_info "Shared report: ${SHARE_OUTPUT}"
print_info "Controller starting. Child runs pick up on-disk edits."

while true; do
  print_info "Spawning child iteration (${SCRIPT_FILE})"

  if ! file_contains_required_model "$SCRIPT_FILE"; then
    print_info "On-disk script missing required model '$REQUIRED_MODEL'; reverting to previous/stable script."
    if [[ -f "$PREV_SCRIPT" ]]; then
      copy_exec "$PREV_SCRIPT" "$SCRIPT_FILE"
    else
      copy_exec "$STABLE_SCRIPT" "$SCRIPT_FILE"
    fi
  fi

  if "$SCRIPT_FILE" --child; then
    child_exit=0
  else
    child_exit=$?
  fi

  print_info "Child exited with code ${child_exit}"

  new_hash=$(compute_hash "$SCRIPT_FILE" || true)
  stable_hash=$(cat "$STABLE_HASH_FILE" 2>/dev/null || true)

  if [[ $child_exit -eq 4 ]]; then
    cooldown "$RETRY_COOLDOWN_SECONDS" "Retry cooldown after failed iteration."
    continue
  fi

  if [[ $child_exit -ne 0 && $child_exit -ne 2 ]]; then
    print_info "Child reported error; attempting rollback to previous script version."
    if [[ -f "$PREV_SCRIPT" ]]; then
      copy_exec "$PREV_SCRIPT" "$SCRIPT_FILE"
      copy_exec "$PREV_SCRIPT" "$STABLE_SCRIPT"
      compute_hash "$STABLE_SCRIPT" > "$STABLE_HASH_FILE" 2>/dev/null || true
      print_info "Rollback applied. Relaunching next iteration using reverted script."
    else
      print_info "No previous script available to rollback to; aborting controller."
      exit 1
    fi
    cooldown "$RETRY_COOLDOWN_SECONDS" "Retry cooldown after rollback."
    continue
  fi

  if [[ -n "$new_hash" && -n "$stable_hash" && "$new_hash" != "$stable_hash" ]]; then
    if ! file_contains_required_model "$SCRIPT_FILE"; then
      print_info "Refusing to adopt new script: missing required model '$REQUIRED_MODEL'. Reverting on-disk script."
      copy_exec "$STABLE_SCRIPT" "$SCRIPT_FILE"
      cooldown "$RETRY_COOLDOWN_SECONDS" "Retry cooldown after rejecting invalid script."
      continue
    fi
    print_info "New script version detected and validated by child; adopting as stable."
    copy_exec "$STABLE_SCRIPT" "$PREV_SCRIPT"
    copy_exec "$SCRIPT_FILE" "$STABLE_SCRIPT"
    compute_hash "$STABLE_SCRIPT" > "$STABLE_HASH_FILE" 2>/dev/null || true
    print_info "Previous stable saved to ${PREV_SCRIPT}."
  fi

  status="$(extract_status_field 'AUTO_LEAN_STATUS' 'continue')"
  if [[ "$status" == "done" ]]; then
    print_info "AUTO_LEAN_STATUS==done; controller exiting cleanly."
    break
  fi

  cooldown "$ITERATION_COOLDOWN_SECONDS" "Iteration complete."
done

exit 0
