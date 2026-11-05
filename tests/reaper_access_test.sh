#!/usr/bin/env bash
set -euo pipefail

# The reaper's access to the container runtime (#17), with fake systemd-run,
# docker, sg and kind binaries (no runtime needed). A systemd user unit gets
# the user manager's groups, not the test's; if the manager started before
# the user joined the socket's group, the unit can't reach the runtime.
#   1. A unit that reaches the runtime is used as is.
#   2. One that can't, for a user in the socket's group: the unit runs the
#      reaper under `sg <group>`.
#   3. If sg doesn't help either: a child-process reaper, with a warning.
#   4. A probe that can't run (old systemd-run) keeps the old behaviour.
#   5. A delete refused with "permission denied" says so, and gives up
#      after 3 attempts so the next launcher's sweep can take over.

[[ -n "${TEST_TMPDIR:-}" ]] || { echo "ERROR: \$TEST_TMPDIR not set" >&2; exit 1; }
RUNFILES="${TEST_SRCDIR:-${RUNFILES_DIR:-${BASH_SOURCE[0]}.runfiles}}"
launcher_dir=""
for candidate in "${RUNFILES}/_main/private" "${RUNFILES}/rules_kind/private"; do
    [[ -f "$candidate/launcher.py" ]] && { launcher_dir="$candidate"; break; }
done
[[ -n "$launcher_dir" ]] || { echo "ERROR: launcher.py not found" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; exit 1; }

export PYTHONPATH="$launcher_dir"
export XDG_RUNTIME_DIR="$TEST_TMPDIR/run" XDG_STATE_HOME="$TEST_TMPDIR/state"
mkdir -p "$XDG_RUNTIME_DIR"
fakes="$TEST_TMPDIR/bin"; mkdir -p "$fakes"
export PATH="$fakes:$PATH" FAKE_LOG="$TEST_TMPDIR/systemd-run.log"

# Our own primary group stands in for `docker`: the socket belongs to it.
sock="$TEST_TMPDIR/docker.sock"; : > "$sock"
export DOCKER_HOST="unix://$sock"
group=$(python3 -c 'import grp, os; print(grp.getgrgid(os.getegid()).gr_name)')
unset KIND_EXPERIMENTAL_PROVIDER

# systemd-run: a unit runs without the group unless FAKE_UNIT_HAS_GROUP=1.
# --wait runs the command (the probe); otherwise it records it (the reaper).
cat > "$fakes/systemd-run" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_NO_PIPE:-}" == 1 && " $* " == *" --pipe "* ]] && { echo "systemd-run: unrecognized option '--pipe'" >&2; exit 1; }
wait=0
while [[ $# -gt 0 && "$1" != -- ]]; do [[ "$1" == --wait ]] && wait=1; shift; done
shift
if [[ "$wait" == 1 ]]; then FAKE_IN_GROUP="${FAKE_UNIT_HAS_GROUP:-0}" exec "$@"; fi
printf '%q ' "$@" >> "$FAKE_LOG"; echo >> "$FAKE_LOG"
SH
# docker: reachable only with the group.
cat > "$fakes/docker" <<'SH'
#!/usr/bin/env bash
[[ "${FAKE_IN_GROUP:-1}" == 1 ]] && exit 0
echo "permission denied while trying to connect to the docker API at unix:///var/run/docker.sock" >&2; exit 1
SH
# sg GROUP -c CMD: grants GROUP if it is $FAKE_SG_GROUP.
cat > "$fakes/sg" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "${FAKE_SG_GROUP:-}" && "$2" == -c ]] || { echo "sg: failed to switch to $1" >&2; exit 1; }
FAKE_IN_GROUP=1 exec sh -c "$3"
SH
# kind: delete is always refused; the cluster stays listed.
cat > "$fakes/kind" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "delete cluster") echo "ERROR: failed to delete cluster: permission denied while trying to connect to the docker API at unix:///var/run/docker.sock" >&2; exit 1 ;;
  "get clusters") echo kind-denied; exit 0 ;;
esac
exit 1
SH
chmod +x "$fakes"/*

prefix() {  # prints the reaper prefix; the launcher's log goes to $TEST_TMPDIR/prefix.log
  python3 -c '
import launcher, os
r = launcher._reaper_prefix(dict(os.environ))
open(os.environ["TEST_TMPDIR"] + "/prefix.out", "w").write(repr(r))
' > "$TEST_TMPDIR/prefix.log" 2>&1
  cat "$TEST_TMPDIR/prefix.out"
}

echo "=== 1. the unit reaches the runtime"
[[ "$(FAKE_UNIT_HAS_GROUP=1 prefix)" == "[]" ]] || fail "unit with access: $(cat "$TEST_TMPDIR/prefix.log")"
echo "PASS: plain unit"

echo "=== 2. the unit lacks the group; sg $group grants it"
out=$(FAKE_SG_GROUP="$group" prefix)
[[ "$out" == "['sg', '$group', '-c']" ]] || fail "want the sg prefix, got $out: $(cat "$TEST_TMPDIR/prefix.log")"
grep -q "isn't in group $group" "$TEST_TMPDIR/prefix.log" || fail "no log line: $(cat "$TEST_TMPDIR/prefix.log")"
: > "$FAKE_LOG"
FAKE_SG_GROUP="$group" python3 -c '
import launcher, os
assert launcher._start_reaper_unit("/fake/kind", "kind-sg", dict(os.environ), "/tmp/x.log") == "rules-kind-reaper-kind-sg"
' >/dev/null 2>&1 || fail "_start_reaper_unit didn't start the unit"
grep -q "^sg $group -c .*--reap-pid\\\\ /fake/kind\\\\ kind-sg" "$FAKE_LOG" \
  || fail "reaper unit not started through sg: $(cat "$FAKE_LOG")"
echo "PASS: reaper unit runs under sg $group"

echo "=== 3. sg doesn't help: child-process reaper, with a warning"
[[ "$(FAKE_SG_GROUP=nope prefix)" == None ]] || fail "want None: $(cat "$TEST_TMPDIR/prefix.log")"
log=$(cat "$TEST_TMPDIR/prefix.log")
grep -q "can't reach the container runtime (permission denied while trying to connect" <<<"$log" || fail "cause not named: $log"
grep -q "using a child process instead" <<<"$log" || fail "fallback not named: $log"
grep -q "picks up group $group" <<<"$log" || fail "no re-login advice: $log"
FAKE_SG_GROUP=nope python3 -c '
import launcher, os, subprocess
r = launcher._start_reaper("/fake/kind", "kind-child", dict(os.environ), os.environ["TEST_TMPDIR"] + "/child.log")
assert isinstance(r, subprocess.Popen), r
launcher._release_reaper(r)
assert r.wait(10) == 0
' >/dev/null 2>&1 || fail "_start_reaper didn't fall back to a child process"
echo "PASS: child-process fallback"

echo "=== 4. the probe can't run (no --pipe): keep using the unit"
[[ "$(FAKE_NO_PIPE=1 prefix)" == "[]" ]] || fail "old systemd-run: $(cat "$TEST_TMPDIR/prefix.log")"
grep -q "couldn't probe" "$TEST_TMPDIR/prefix.log" || fail "no note: $(cat "$TEST_TMPDIR/prefix.log")"
echo "PASS: unknown probe result keeps the unit"

echo "=== 5. a refused delete says why and gives up after 3 attempts"
log="$TEST_TMPDIR/delete.log"
python3 -c '
import launcher, os
launcher.time.sleep = lambda s: None
assert launcher._delete_until_gone("kind", "kind-denied", dict(os.environ)) is False
' > "$log" 2>&1 || fail "_delete_until_gone: $(cat "$log")"
[[ "$(grep -c "the reaper cannot reach the container runtime: permission denied on $sock" "$log")" == 3 ]] \
  || fail "want 3 permission errors: $(cat "$log")"
grep -q "giving up on kind-denied after 3 permission errors" "$log" || fail "didn't give up early: $(cat "$log")"
grep -q "still present after kind delete" "$log" && fail "misleading 'still present' message: $(cat "$log")"
echo "PASS: permission error named; gave up after 3"
echo "PASS"
