#!/usr/bin/env bash
set -euo pipefail

# Launcher pieces that need no container runtime:
#   - RULES_KIND_MAX_CLUSTERS slots (#15): a second launcher waits, names the
#     holder, and gets the slot once the holder is SIGKILLed; 0 = no limit.
#   - RULES_KIND_SLOT_DIR holds slots any user can lock.
#   - _log survives a closed stdout (#12), so teardown still reaches kind.
#   - _create_cluster retries when two clusters race to create podman's
#     `kind` network ("network already exists"), and only then.

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

# --- 5. podman `kind` network race ------------------------------------------
# A fake kind: fails like kind's podman provider does when another cluster
# created the network first, a set number of times, then succeeds. Each call
# appends to $calls.
echo "=== kind network race"
fake="$TEST_TMPDIR/fake-kind"
calls="$TEST_TMPDIR/kind-calls"
cat > "$fake" <<'FAKE'
#!/usr/bin/env bash
echo call >> "$FAKE_CALLS"
n=$(wc -l < "$FAKE_CALLS")
if (( n <= FAKE_FAILURES )); then
    echo "ERROR: failed to create cluster: failed to ensure podman network: command \"podman network create -d=bridge kind\" failed with error: exit status 125" >&2
    echo "Command Output: Error: ${FAKE_MESSAGE}" >&2
    exit 1
fi
FAKE
chmod +x "$fake"
race() { # <failures> <message>; prints the number of kind calls, exits like _create_cluster
    rm -f "$calls"
    FAKE_CALLS="$calls" FAKE_FAILURES="$1" FAKE_MESSAGE="$2" python3 -c '
import os, sys, launcher
launcher.time.sleep = lambda s: None
launcher._create_cluster(sys.argv[1], "kind-race", "img", None, dict(os.environ))
' "$fake" > "$TEST_TMPDIR/race.log" 2>&1
}
race 2 "network name kind already used: network already exists" \
    || { cat "$TEST_TMPDIR/race.log" >&2; echo "FAIL: create failed after two lost races" >&2; exit 1; }
[[ "$(wc -l < "$calls")" == 3 ]] || { echo "FAIL: expected 3 kind calls, got $(wc -l < "$calls")" >&2; exit 1; }
grep -q "created the kind network at the same time; retrying" "$TEST_TMPDIR/race.log" \
    || { cat "$TEST_TMPDIR/race.log" >&2; echo "FAIL: no retry message" >&2; exit 1; }
echo "PASS: a lost network race is retried"
if race 5 "network name kind already used: network already exists"; then
    echo "FAIL: create succeeded although every attempt lost the race" >&2; exit 1
fi
[[ "$(wc -l < "$calls")" == 3 ]] || { echo "FAIL: expected 3 attempts, got $(wc -l < "$calls")" >&2; exit 1; }
grep -q "network already exists" "$TEST_TMPDIR/race.log" || { echo "FAIL: error lost kind's output" >&2; exit 1; }
echo "PASS: retries stop after 3 attempts, with kind's error"
if race 1 "some other failure"; then
    echo "FAIL: create succeeded after an unrelated failure" >&2; exit 1
fi
[[ "$(wc -l < "$calls")" == 1 ]] || { echo "FAIL: an unrelated failure was retried" >&2; exit 1; }
echo "PASS: other failures are not retried"

echo "PASS"
