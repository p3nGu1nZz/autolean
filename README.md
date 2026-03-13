# autolean

A lightweight controller/worker wrapper that runs an autonomous "autolean" loop using the `copilot` CLI to iteratively improve and verify Lean mechanizations and linked paper exposition.

This README describes how the script is intended to be used inside the CatGame repository. Copy this file into an external repository alongside `autolean.sh` if you want to reuse the same workflow.

## Purpose

- Run bounded Copilot/autopilot iterations that inspect `./data/copilot/lean_update_output.md`, make small, verifiable edits to Lean sources and supporting scripts, and write a concise iteration report back to `data/copilot/lean_update_output.md`.
- Provide a controller that spawns a short-lived child worker for each iteration so on-disk edits to the controller script are picked up between iterations.

## Important files & state (repo-relative)

- `data/copilot/lean_update_output.md` — shared iteration report (the controller and copilot worker overwrite this each iteration)
- `data/copilot/autolean.sh_history/` — archived iteration reports
- `data/copilot/autolean.sh_prompt.md` — prompt built for each Copilot invocation
- `data/copilot/autolean.sh_loop.log` — controller run log
- `data/copilot/autolean.sh_final_summary.md` — final summary when loop completes
- `data/copilot/autolean.sh_stable.sh` — current stable copy of the script adopted by the controller
- `data/copilot/autolean.sh_prev.sh` — previous stable copy (rollback target)
- `data/copilot/autolean.sh.pid` — controller PID file

## Prerequisites

- POSIX-compatible shell (bash recommended)
- `copilot` CLI available on PATH and authorized for the required model
- `./scripts/lean.sh` (or a working Lean toolchain) is expected to be present for verification steps
- Common utilities: `sed`, `sha256sum`/`shasum`/`md5sum`, `stat`

Note: the script enforces a REQUIRED_MODEL in the on-disk script (default in the distributed version is `gpt-5.1-codex-mini`). Ensure your `copilot` installation can use that model or edit the script copies in `data/copilot/` if you intentionally want a different model.

## Usage

Run from the repository root.

- Controller (long-running):

```bash
./scripts/copilot/autolean.sh
```

- Single child/worker iteration (debug):

```bash
./scripts/copilot/autolean.sh --child
# or equivalently
./scripts/copilot/autolean.sh --worker
```

- Print controller status (paths, hashes, recent logs):

```bash
./scripts/copilot/autolean.sh --status
```

- Kill all running controller instances that match this script path:

```bash
./scripts/copilot/autolean.sh --kill
```

- Help:

```bash
./scripts/copilot/autolean.sh --help
```

## Environment variables (optional)

- `AUTO_LEAN_MAX_PREVIOUS_OUTPUT_BYTES` — bytes of previous shared output to include in the prompt (default: 12000)
- `AUTO_LEAN_MAX_SHARE_LINES` — maximum lines to keep in the shared report (default: 120)
- `AUTO_LEAN_MAX_HISTORY_FILES` — how many archived iteration files to retain (default: 40)
- `AUTO_LEAN_ITERATION_COOLDOWN_SECONDS` — sleep between successful iterations (default: 300)
- `AUTO_LEAN_RETRY_COOLDOWN_SECONDS` — sleep after a failed iteration (default: 60)
- `AUTO_LEAN_SLEEP_SECONDS` — legacy alias used if `AUTO_LEAN_ITERATION_COOLDOWN_SECONDS` is unset

## How it works (brief)

1. Controller ensures `data/copilot/` state exists and writes a stable copy of the script under `data/copilot/autolean.sh_stable.sh`.
2. Each loop the controller spawns a child using `--child` so edits to the on-disk script take effect on the next cycle.
3. The child builds a prompt (including a bounded excerpt of previous output), runs `copilot --autopilot --no-ask-user --plain-diff ...` to perform edits, and expects the agent to overwrite `data/copilot/lean_update_output.md` following a small footer contract:

```
AUTO_LEAN_STATUS: continue|done
AUTO_LEAN_REASON: <single line>
AUTO_LEAN_NEXT: <single line>
```

4. The controller archives iteration reports, truncates overly long reports to keep them bounded, and adopts new script versions only if a child validates them.
5. The controller exits when `AUTO_LEAN_STATUS: done` is observed.

## Exit codes (child/worker)

- `0` = success (recommendation: continue)
- `2` = finished (the agent reported `AUTO_LEAN_STATUS: done`)
- `>2` = error (controller will attempt rollback or retry)

## Safety & warnings

- This workflow runs an autonomous agent with `--autopilot --no-ask-user` and `--allow-all-paths --allow-all-tools`. Only run on repositories you trust and on machines where automatic edits are acceptable to test.
- The Copilot worker is expected to make small, verifiable changes. Always review iteration diffs and test runs before merging edits.

## Troubleshooting

- If the controller refuses to start, check `data/copilot/autolean.sh.pid` and `data/copilot/autolean.sh_loop.log`.
- If Copilot fails, run a single child with `--child` to inspect stdout/stderr and the prompt file at `data/copilot/autolean.sh_prompt.md`.
- If the shared report becomes malformed, the controller will recover it into a minimal report; inspect the recovered `data/copilot/lean_update_output.md` and the run log.

## Example quick workflow

```bash
# view status
./scripts/copilot/autolean.sh --status

# run a single iteration to observe behavior
./scripts/copilot/autolean.sh --child

# start controller in background (careful — autonomous edits enabled)
nohup ./scripts/copilot/autolean.sh > /tmp/autolean.log 2>&1 &
```

## Notes

- The script intentionally keeps reports small and uses a strict footer contract so external automation can parse the loop output reliably.
- The canonical Lean wrapper for verification in this repository is `./scripts/lean.sh` — prefer it for any manual checks that the agent requests.

---
