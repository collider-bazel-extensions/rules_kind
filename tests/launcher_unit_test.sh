#!/usr/bin/env bash
set -euo pipefail

# Launcher pieces that need no container runtime:
#   - RULES_KIND_MAX_CLUSTERS slots (#15): a second launcher waits, names the
#     holder, and gets the slot once the holder is SIGKILLed; 0 = no limit.
#   - RULES_KIND_SLOT_DIR holds slots any user can lock.
#   - _log survives a closed stdout (#12), so teardown still reaches kind.

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"
launcher_dir=""
for candidate in "${RUNFILES}/_main/private" "${RUNFILES}/rules_kind/private"; do
    [[ -f "$candidate/launcher.py" ]] && { launcher_dir="$candidate"; break; }
done
[[ -n "$launcher_dir" ]] || { echo "ERROR: launcher.py not found" >&2; exit 1; }

export PYTHONPATH="$launcher_dir"
export XDG_RUNTIME_DIR="$TEST_TMPDIR/run"
export XDG_STATE_HOME="$TEST_TMPDIR/state"
mkdir -p "$XDG_RUNTIME_DIR"

# --- 1. One slot: the second launcher waits for the first ------------------
echo "=== RULES_KIND_MAX_CLUSTERS=1"
export RULES_KIND_MAX_CLUSTERS=1
python3 -c '
import launcher, time
launcher._acquire_slot("kind-holder", "first")
print("holding", flush=True)
time.sleep(600)
' > "$TEST_TMPDIR/a.log" 2>&1 &
holder=$!
for _ in $(seq 50); do grep -q holding "$TEST_TMPDIR/a.log" && break; sleep 0.1; done
grep -q holding "$TEST_TMPDIR/a.log" || { cat "$TEST_TMPDIR/a.log" >&2; echo "FAIL: holder did not get the slot" >&2; exit 1; }

python3 -c '
import launcher
launcher._acquire_slot("kind-waiter", "second")
print("acquired", flush=True)
' > "$TEST_TMPDIR/b.log" 2>&1 &
waiter=$!
sleep 3
grep -q "acquired" "$TEST_TMPDIR/b.log" && { echo "FAIL: second launcher got a slot that was taken" >&2; exit 1; }
grep -q "waiting for a cluster slot (RULES_KIND_MAX_CLUSTERS=1); held by: kind-holder pid $holder target first" "$TEST_TMPDIR/b.log" \
    || { cat "$TEST_TMPDIR/b.log" >&2; echo "FAIL: waiting message does not name the holder" >&2; exit 1; }
echo "PASS: second launcher waits and names the holder"

kill -KILL "$holder"
wait "$holder" 2>/dev/null || true
for _ in $(seq 50); do grep -q acquired "$TEST_TMPDIR/b.log" && break; sleep 0.2; done
grep -q acquired "$TEST_TMPDIR/b.log" || { cat "$TEST_TMPDIR/b.log" >&2; echo "FAIL: slot not freed by SIGKILL" >&2; exit 1; }
wait "$waiter"
echo "PASS: SIGKILLed holder's slot is taken over"

# --- 2. No limit -------------------------------------------------------------
echo "=== RULES_KIND_MAX_CLUSTERS=0"
RULES_KIND_MAX_CLUSTERS=0 timeout 10 python3 -c '
import launcher
assert launcher._acquire_slot("kind-x", "t") is None
' || { echo "FAIL: RULES_KIND_MAX_CLUSTERS=0 still limits" >&2; exit 1; }
echo "PASS: 0 means no limit"

# --- 3. RULES_KIND_SLOT_DIR -----------------------------------------------------
echo "=== RULES_KIND_SLOT_DIR"
shared="$TEST_TMPDIR/shared-slots"
RULES_KIND_SLOT_DIR="$shared" RULES_KIND_MAX_CLUSTERS=1 timeout 10 python3 -c '
import launcher
assert launcher._acquire_slot("kind-x", "t") is not None
'
[[ "$(stat -c %a "$shared/slot-0")" == 666 ]] || { echo "FAIL: shared slot file not mode 666" >&2; exit 1; }
echo "PASS: slots in RULES_KIND_SLOT_DIR, lockable by other users"

# --- 4. Closed stdout -------------------------------------------------------
echo "=== _log with a closed stdout"
python3 -c '
import os, sys, launcher
r, w = os.pipe()
os.close(r)
os.dup2(w, sys.stdout.fileno())
launcher._log("first line to a closed pipe")
launcher._log("second line")
open(sys.argv[1], "w").write("reached")
' "$TEST_TMPDIR/after_log" 2>"$TEST_TMPDIR/c.err" || true
[[ "$(cat "$TEST_TMPDIR/after_log" 2>/dev/null)" == reached ]] \
    || { cat "$TEST_TMPDIR/c.err" >&2; echo "FAIL: _log raised on a closed stdout" >&2; exit 1; }
echo "PASS: _log tolerates a closed stdout"

echo "PASS"
