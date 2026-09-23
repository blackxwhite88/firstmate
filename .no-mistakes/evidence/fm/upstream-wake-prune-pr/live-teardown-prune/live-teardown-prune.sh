#!/usr/bin/env bash
# Live scenario: does tearing down a task through the real bin/fm-teardown.sh
# prune that task's leftover durable wake rows while leaving live siblings'
# rows untouched?
#
# Real in this run:
#   - the real bin/fm-teardown.sh and bin/fm-wake-lib.sh under test
#   - a real tmux server (private TMUX_TMPDIR, never the operator's default)
#     hosting a real task window
#   - a real git project + worktree, a real bare origin and fork remote
#   - the real durable .wake-queue, written through the real fm_wake_append
# Environment doubles (isolation only; not the code under test):
#   - treehouse/gh/gh-axi/no-mistakes stubs so the run is hermetic
#
# Modes:
#   ./live-teardown-prune.sh target   -> run the checked-out (target) code
#   ./live-teardown-prune.sh base     -> run the pre-change fef37b9 versions of
#                                        bin/fm-teardown.sh + bin/fm-wake-lib.sh
#                                        (regression "fails before, passes after")
set -u

REPO=${REPO:-/home/local/.no-mistakes/worktrees/b39db14c8322/01M36K50TAANJC3SS035Y334JX}
MODE=${1:-target}
BASE_REF=${BASE_REF:-fef37b9}

OUTDIR=${OUTDIR:-/home/local/.no-mistakes/evidence/01M36K50TAANJC3SS035Y334JX/live-teardown-prune}
mkdir -p "$OUTDIR"
LOG="$OUTDIR/$MODE.log"
: > "$LOG"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
run() { "$@" >>"$LOG" 2>&1; }

CASE=$(mktemp -d /tmp/fm-wake-prune-live.XXXXXX)
STATE="$CASE/state"
DATA="$CASE/data"
CONFIG="$CASE/config"
FAKEBIN="$CASE/fakebin"
TMUXDIR="$CASE/tmux"
mkdir -p "$STATE" "$DATA" "$CONFIG" "$FAKEBIN" "$TMUXDIR"
export TMUX_TMPDIR="$TMUXDIR"
unset TMUX

cleanup() {
  tmux kill-server >/dev/null 2>&1 || true
  rm -rf "$CASE"
}
trap cleanup EXIT

# --- fake external tools (isolation only) ----------------------------------
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2
exit 1
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status) exit 0 ;;
      abort) exit 0 ;;
    esac ;;
  runs) exit 0 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/treehouse" "$FAKEBIN/gh-axi" "$FAKEBIN/gh" "$FAKEBIN/no-mistakes"

# --- real git project + worktree -------------------------------------------
git init -q --bare "$CASE/origin.git" >>"$LOG" 2>&1
git -C "$CASE/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$CASE/origin.git" "$CASE/_seed" >>"$LOG" 2>&1
git -C "$CASE/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
git -C "$CASE/_seed" push -q origin main
rm -rf "$CASE/_seed"
git clone -q "$CASE/origin.git" "$CASE/project" >>"$LOG" 2>&1
git -C "$CASE/project" remote set-head origin main 2>/dev/null || true
git -C "$CASE/project" worktree add -q -b fm/task-x1 "$CASE/wt" main >>"$LOG" 2>&1
# Real landed work: push the task branch to a fork remote and fetch it, exactly
# the shape teardown's landed-work gate accepts (a fork counts as a remote).
git init -q --bare "$CASE/fork.git" >>"$LOG" 2>&1
git -C "$CASE/project" remote add fork "$CASE/fork.git"
git -C "$CASE/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "task work"
git -C "$CASE/wt" push -q fork fm/task-x1
git -C "$CASE/project" fetch -q fork
touch "$STATE/.last-watcher-beat"

# --- real tmux endpoint for the task ---------------------------------------
tmux new-session -d -s firstmate -n fm-task-x1 'sleep 600' >>"$LOG" 2>&1
tmux new-window -d -t firstmate: -n fm-task-x10 'sleep 600' >>"$LOG" 2>&1
tmux list-windows -a -F '#{session_name}:#{window_name}' >>"$LOG" 2>&1

# --- task record ------------------------------------------------------------
printf '%s\n' \
  'window=firstmate:fm-task-x1' \
  'endpoint_task_id=task-x1' \
  "worktree=$CASE/wt" \
  "project=$CASE/project" \
  'kind=ship' \
  'mode=local-only' \
  'spawn_gen=live-prune-task-x1' \
  > "$STATE/task-x1.meta"

# --- real durable wake rows (written through the real library) -------------
seed_wakes() {
  FM_STATE_OVERRIDE="$STATE" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append stale "firstmate:fm-task-x1" "stale: firstmate:fm-task-x1" || exit 1
    fm_wake_append signal "task-x1.status" "signal: $2/task-x1.status" || exit 1
    fm_wake_append signal "task-x1.turn-ended" "signal: $2/task-x1.turn-ended" || exit 1
    fm_wake_append check "$2/task-x1.check.sh" "check: $2/task-x1.check.sh: merged: https://example.test/pr/1" || exit 1
    fm_wake_append stale "firstmate:fm-task-x10" "stale: firstmate:fm-task-x10" || exit 1
    fm_wake_append signal "task-x10.status" "signal: $2/task-x10.status" || exit 1
    fm_wake_append check "$2/task-x10.check.sh" "check: $2/task-x10.check.sh: merged: https://example.test/pr/10" || exit 1
    fm_wake_append signal "task-y2.turn-ended" "signal: $2/task-y2.turn-ended" || exit 1
    fm_wake_append heartbeat heartbeat heartbeat || exit 1
    printf "malformed-row-kept\n" >> "$2/.wake-queue"
  ' _ "$REPO" "$STATE"
}
# An issue #3419 shape: the watcher's paired bookkeeping marker for the task's
# turn-ended file. The prune does not touch it (the PR body scopes that to
# adjacent #5252); record whether it survives so the evidence is explicit.
touch "$STATE/.seen-task-x1_turn-ended" "$STATE/.seen-task-x1_status"
if [ "$MODE" != noqueue ]; then
  seed_wakes || { say "FATAL: could not seed wake rows"; exit 1; }
fi

queue_keys() {
  FM_STATE_OVERRIDE="$STATE" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    for kind in stale signal check heartbeat; do
      printf "%s: " "$kind"
      fm_wake_queued_keys "$kind" | paste -sd, - || true
      printf "\n"
    done
  ' _ "$REPO"
}

say "=== $MODE: wake rows seeded (queue before teardown) ==="
if [ "$MODE" = noqueue ]; then
  if [ -e "$STATE/.wake-queue" ]; then
    say "ASSERT FAIL: no-queue case unexpectedly has a .wake-queue"
  else
    say "ASSERT OK: no .wake-queue exists before teardown"
  fi
else
  queue_keys | tee -a "$LOG"
fi

# --- choose which teardown/wake-lib to run ---------------------------------
if [ "$MODE" = base ]; then
  BINDIR="$CASE/binbase"
  cp -a "$REPO/bin" "$BINDIR"
  git -C "$REPO" show "$BASE_REF:bin/fm-teardown.sh" > "$BINDIR/fm-teardown.sh"
  git -C "$REPO" show "$BASE_REF:bin/fm-wake-lib.sh" > "$BINDIR/fm-wake-lib.sh"
  chmod +x "$BINDIR/fm-teardown.sh" "$BINDIR/fm-wake-lib.sh"
  TEARDOWN="$BINDIR/fm-teardown.sh"
  say "--- running pre-change teardown ($BASE_REF) ---"
else
  TEARDOWN="$REPO/bin/fm-teardown.sh"
  say "--- running target teardown ($(git -C "$REPO" rev-parse --short HEAD)) ---"
fi

set +e
FM_ROOT_OVERRIDE="$REPO" \
FM_STATE_OVERRIDE="$STATE" \
FM_DATA_OVERRIDE="$DATA" \
FM_CONFIG_OVERRIDE="$CONFIG" \
FM_GATE_REFUSE_BYPASS=1 \
PATH="$FAKEBIN:$PATH" \
  "$TEARDOWN" task-x1 >>"$LOG" 2>&1
rc=$?
set -e
say "teardown rc=$rc"
say "--- teardown stdout/stderr tail ---"
tail -n 20 "$LOG" > "$OUTDIR/$MODE.teardown-tail.txt"

say "=== $MODE: wake rows after teardown ==="
if [ "$MODE" = noqueue ]; then
  if [ "$rc" -eq 0 ] && [ ! -e "$STATE/.wake-queue" ]; then
    say "ASSERT OK: teardown succeeded with no wake queue and created none"
    say "LIVE SCENARIO PASS"
    exit 0
  fi
  say "ASSERT FAIL: teardown rc=$rc with no wake queue (or created one)"
  say "LIVE SCENARIO FAIL"
  exit 1
fi
queue_keys | tee -a "$LOG"
say "--- issue #3419 bookkeeping markers after teardown (out of this change's scope) ---"
for m in .seen-task-x1_turn-ended .seen-task-x1_status; do
  if [ -e "$STATE/$m" ]; then say "PRESENT: $m"; else say "ABSENT: $m"; fi
done

# --- assertions -------------------------------------------------------------
fail=0
assert_absent_key() { # <kind> <key> <label>
  if FM_STATE_OVERRIDE="$STATE" bash -c '
        . "$1/bin/fm-wake-lib.sh"
        fm_wake_queued_keys "$2" | grep -Fxq "$3"
      ' _ "$REPO" "$1" "$2"; then
    say "ASSERT FAIL: $3 ($1/$2 still queued)"; fail=1
  else
    say "ASSERT OK: $3"
  fi
}
assert_present_key() {
  if FM_STATE_OVERRIDE="$STATE" bash -c '
        . "$1/bin/fm-wake-lib.sh"
        fm_wake_queued_keys "$2" | grep -Fxq "$3"
      ' _ "$REPO" "$1" "$2"; then
    say "ASSERT OK: $3"
  else
    say "ASSERT FAIL: $3 ($1/$2 missing)"; fail=1
  fi
}

assert_absent_key stale "firstmate:fm-task-x1" "retired task's stale window wake pruned"
assert_absent_key signal "task-x1.status" "retired task's status signal wake pruned"
assert_absent_key signal "task-x1.turn-ended" "retired task's turn-ended signal wake pruned"
assert_absent_key check "$STATE/task-x1.check.sh" "retired task's check wake pruned"

assert_present_key stale "firstmate:fm-task-x10" "sibling task-x10 stale wake preserved (prefix collision)"
assert_present_key signal "task-x10.status" "sibling task-x10 status wake preserved (prefix collision)"
assert_present_key check "$STATE/task-x10.check.sh" "sibling task-x10 check wake preserved (prefix collision)"
assert_present_key signal "task-y2.turn-ended" "unrelated task-y2 signal wake preserved"
assert_present_key heartbeat heartbeat "heartbeat row preserved"
if grep -Fxq 'malformed-row-kept' "$STATE/.wake-queue"; then
  say "ASSERT OK: malformed short row preserved"
else
  say "ASSERT FAIL: malformed short row was dropped"; fail=1
fi

# The queue must still be a readable, single-link regular file.
[ -f "$STATE/.wake-queue" ] && [ ! -L "$STATE/.wake-queue" ] \
  && say "ASSERT OK: .wake-queue is a regular file" \
  || { say "ASSERT FAIL: .wake-queue missing or not a regular file"; fail=1; }

if [ "$MODE" = base ]; then
  # The regression contract: pre-change teardown must leave the retired task's
  # rows behind (that is the bug), so the "absent" assertions above are EXPECTED
  # to fail here.
  say "=== base run expectation: retired rows should still be present (bug reproduced) ==="
  if FM_STATE_OVERRIDE="$STATE" bash -c '
        . "$1/bin/fm-wake-lib.sh"
        fm_wake_queued_keys signal | grep -Fxq task-x1.turn-ended
      ' _ "$REPO"; then
    say "REGRESSION CONFIRMED: pre-change teardown left task-x1.turn-ended queued"
    exit 0
  fi
  say "REGRESSION NOT CONFIRMED: pre-change teardown pruned the row"
  exit 2
fi

[ "$fail" -eq 0 ] && { say "LIVE SCENARIO PASS"; exit 0; }
say "LIVE SCENARIO FAIL"; exit 1