#!/usr/bin/env python3
"""kube_bench_test runner: kube-bench (CIS Kubernetes Benchmark) on a kind cluster.

Modes:
  --run <config.json>
      The test. Gets the cluster (the kind_cluster's env file if it already
      exists -- the cluster is a rules_itest service -- else starts the
      cluster's launcher and stops it at the end), runs kube-bench as one Job
      per node with the host PID namespace and the node's files mounted,
      writes each node's raw JSON to $TEST_UNDECLARED_OUTPUTS_DIR/kube-bench/,
      prints a summary, and fails on a FAIL result whose check id is not in
      the ignore file, or on an expired ignore entry.
  --check-ignore <file> [--shown <path>] [--stamp <out>]
      The build-time validation action: the ignore file's shape only.
  --evaluate <ignore file|-> <report.json>...
      Evaluate saved kube-bench JSON (no cluster), print the summary, exit
      like the test would. For trying out an ignore file.

The ignore file:

    checks:
      - id: "1.1.12"            # kube-bench check id (test_number)
        reason: why this FAIL is accepted
        expires: 2027-06-30     # optional, YYYY-MM-DD

Python 3.8+, standard library only.
"""

import datetime
import json
import os
import re
import secrets
import signal
import subprocess
import sys
import time

# ---- the YAML subset ---------------------------------------------------------------
# Same reader as rules_trivy's ignore files (rules_trivy/private/trivy.py):
# block mappings and sequences, flow lists of scalars, plain / 'single' /
# "double"-quoted scalars, comments -- and rejects anything else by line
# instead of guessing (anchors, tags, multi-line scalars, flow mappings).
# Every scalar stays a string: `id: 1.2` is "1.2", `expires: 2027-01-31` is
# "2027-01-31".


class IgnoreError(Exception):
    pass


_KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*:(?:\s+(.*))?$")


def _strip_comment(s):
    out, quote = [], None
    for i, c in enumerate(s):
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            break
        out.append(c)
    return "".join(out).rstrip()


def _scalar(text, line):
    t = text.strip()
    if t == "":
        return None
    if t[0] == '"':
        if len(t) < 2 or not t.endswith('"'):
            raise IgnoreError("line {}: unterminated double-quoted string".format(line))
        try:
            return json.loads(t)
        except ValueError:
            raise IgnoreError("line {}: unsupported escape in {}".format(line, t))
    if t[0] == "'":
        if len(t) < 2 or not t.endswith("'"):
            raise IgnoreError("line {}: unterminated single-quoted string".format(line))
        return t[1:-1].replace("''", "'")
    if t[0] in "&*!|>{%@`":
        raise IgnoreError("line {}: unsupported YAML ({!r}): use plain or quoted strings".format(line, t[0]))
    if t[0] == "[":
        return _flow_list(t, line)
    return t


def _flow_list(t, line):
    if not t.endswith("]"):
        raise IgnoreError("line {}: a flow list must close on the same line".format(line))
    body = t[1:-1].strip()
    if not body:
        return []
    items, cur, quote = [], [], None
    for c in body:
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            cur.append(c)
        elif c == ",":
            items.append("".join(cur))
            cur = []
        elif c in "[]{}":
            raise IgnoreError("line {}: nested flow collections are not supported".format(line))
        else:
            cur.append(c)
    items.append("".join(cur))
    out = []
    for it in items:
        v = _scalar(it, line)
        if v is None:
            raise IgnoreError("line {}: empty item in flow list".format(line))
        if isinstance(v, list):
            raise IgnoreError("line {}: nested lists are not supported".format(line))
        out.append(v)
    return out


def parse_yaml_subset(text):
    lines = []
    for n, raw in enumerate(text.splitlines(), 1):
        body = raw.rstrip()
        stripped = body.lstrip(" ")
        if not stripped or stripped.startswith("#"):
            continue
        if body.lstrip(" \t") != stripped or "\t" in body[: len(body) - len(stripped)]:
            raise IgnoreError("line {}: tab in indentation".format(n))
        if stripped == "---" and not lines:
            continue
        lines.append([len(body) - len(stripped), _strip_comment(stripped), n])
    if not lines:
        return None
    value, i = _block(lines, 0, lines[0][0])
    if i < len(lines):
        raise IgnoreError("line {}: unexpected content (check the indentation)".format(lines[i][2]))
    return value


def _block(lines, i, indent):
    if lines[i][1] == "-" or lines[i][1].startswith("- "):
        return _sequence(lines, i, indent)
    return _mapping(lines, i, indent)


def _sequence(lines, i, indent):
    out = []
    while i < len(lines) and lines[i][0] == indent and (lines[i][1] == "-" or lines[i][1].startswith("- ")):
        content, n = lines[i][1], lines[i][2]
        rest = content[1:].lstrip(" ")
        if not rest:
            if i + 1 < len(lines) and lines[i + 1][0] > indent:
                v, i = _block(lines, i + 1, lines[i + 1][0])
                out.append(v)
            else:
                raise IgnoreError("line {}: empty list item".format(n))
        elif _KEY.match(rest):
            # `- key: value` starts a mapping whose keys align with `key`.
            col = indent + (len(content) - len(rest))
            lines[i] = [col, rest, n]
            v, i = _mapping(lines, i, col)
            out.append(v)
        else:
            out.append(_scalar(rest, n))
            i += 1
    if i < len(lines) and lines[i][0] > indent:
        raise IgnoreError("line {}: unexpected indentation".format(lines[i][2]))
    return out, i


def _mapping(lines, i, indent):
    out = {}
    while i < len(lines) and lines[i][0] == indent:
        content, n = lines[i][1], lines[i][2]
        if content == "-" or content.startswith("- "):
            break
        m = _KEY.match(content)
        if not m:
            raise IgnoreError("line {}: expected `key: value`, got {!r}".format(n, content))
        key, rest = m.group(1), m.group(2)
        if key in out:
            raise IgnoreError("line {}: duplicate key '{}'".format(n, key))
        i += 1
        if rest is None or rest.strip() == "":
            if i < len(lines) and lines[i][0] > indent:
                out[key], i = _block(lines, i, lines[i][0])
            elif i < len(lines) and lines[i][0] == indent and (lines[i][1] == "-" or lines[i][1].startswith("- ")):
                out[key], i = _sequence(lines, i, indent)
            else:
                out[key] = None
        else:
            out[key] = _scalar(rest, n)
    if i < len(lines) and lines[i][0] > indent:
        raise IgnoreError("line {}: unexpected indentation".format(lines[i][2]))
    return out, i


# ---- the ignore file -----------------------------------------------------------------

_ENTRY_KEYS = ("id", "reason", "expires")
_ID = re.compile(r"^\d+(\.\d+)+$")
_ENTRY_HINTS = {
    "statement": "the reason goes in 'reason'",
    "comment": "the reason goes in 'reason'",
    "justification": "the reason goes in 'reason'",
    "expired_at": "the expiry goes in 'expires'",
    "expires_at": "the expiry goes in 'expires'",
    "expiry": "the expiry goes in 'expires'",
    "effectiveUntil": "the expiry goes in 'expires'",
    "ignoreUntil": "the expiry goes in 'expires'",
    "until": "the expiry goes in 'expires'",
    "test_number": "the check id goes in 'id'",
    "check": "the check id goes in 'id'",
}
_TOP_HINTS = {
    "ignore": "the entries go under 'checks:'",
    "ignored": "the entries go under 'checks:'",
    "IgnoredVulns": "the entries go under 'checks:'",
    "misconfigurations": "the entries go under 'checks:'",
}


def _date(v):
    if not isinstance(v, str) or not re.match(r"^\d{4}-\d{2}-\d{2}$", v):
        return None
    try:
        return datetime.date.fromisoformat(v)
    except ValueError:
        return None


def parse_ignore(text):
    """-> [entry {id, reason, expires (date|None)}]. Raises IgnoreError
    listing every problem."""
    doc = parse_yaml_subset(text)
    if doc is None:
        return []
    if not isinstance(doc, dict):
        raise IgnoreError("  expected a mapping with a `checks:` list")
    problems, entries, seen = [], [], {}
    for key in doc:
        if key != "checks":
            hint = _TOP_HINTS.get(key)
            problems.append("  unknown key '{}'{} (known: checks)".format(key, " -- " + hint if hint else ""))
    checks = doc.get("checks")
    if checks is None:
        checks = []
    if not isinstance(checks, list):
        problems.append("  checks: expected a list of entries")
        checks = []
    for idx, e in enumerate(checks):
        where = "checks[{}]".format(idx)
        if not isinstance(e, dict):
            problems.append("  {}: expected a mapping with id and reason".format(where))
            continue
        cid = e.get("id")
        if isinstance(cid, str) and cid.strip():
            where += " ({})".format(cid)
        for k in e:
            if k not in _ENTRY_KEYS:
                hint = _ENTRY_HINTS.get(k)
                problems.append("  {}: unknown key '{}'{} (known: {})".format(
                    where, k, " -- " + hint if hint else "", ", ".join(_ENTRY_KEYS)))
        if not isinstance(cid, str) or not cid.strip():
            problems.append("  {}: 'id' is missing or empty (the kube-bench check id, e.g. 1.2.15)".format(where))
        elif not _ID.match(cid):
            problems.append("  {}: id {!r} is not a check id such as 1.2.15".format(where, cid))
        elif cid in seen:
            problems.append("  {}: id {} is already listed at checks[{}]".format(where, cid, seen[cid]))
        else:
            seen[cid] = idx
        reason = e.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            problems.append("  {}: 'reason' is missing or empty (why this FAIL is accepted)".format(where))
        expires = None
        if "expires" in e:
            expires = _date(e["expires"])
            if expires is None:
                problems.append("  {}: expires {!r} is not a date (YYYY-MM-DD)".format(where, e["expires"]))
        entries.append({"id": cid, "reason": reason, "expires": expires})
    if problems:
        raise IgnoreError("\n".join(problems))
    return entries


def load_ignore(path):
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise IgnoreError("  cannot read it: {}".format(e))
    return parse_ignore(text)


def expired_entries(entries, today):
    """An entry expires at the start of its `expires` day (UTC), as in
    rules_trivy."""
    return [e for e in entries if e["expires"] is not None and today >= e["expires"]]


def utc_today():
    return datetime.datetime.now(datetime.timezone.utc).date()


# ---- results ---------------------------------------------------------------------------

STATUSES = ("PASS", "FAIL", "WARN", "INFO")


def _id_key(cid):
    try:
        return tuple(int(p) for p in cid.split("."))
    except ValueError:
        return (1 << 30,)


def checks_of(report):
    """kube-bench --json output -> [check dict]."""
    out = []
    for control in report.get("Controls") or []:
        for test in control.get("tests") or []:
            for r in test.get("results") or []:
                out.append({
                    "id": str(r.get("test_number", "")),
                    "text": r.get("test_desc", ""),
                    "status": r.get("status", ""),
                    "remediation": r.get("remediation", ""),
                    "node_type": control.get("node_type", ""),
                    "benchmark": control.get("version", ""),
                })
    return out


def evaluate(reports, entries, today, fail_on_stale=False):
    """reports: [(node, kube-bench JSON)]. -> result dict (see summary())."""
    by_id = {}  # id -> {text, remediation, statuses {node: status}}
    counts = {s: 0 for s in STATUSES}
    problems = []
    for node, report in reports:
        checks = checks_of(report)
        if not checks:
            problems.append("kube-bench reported no checks on node {}".format(node))
        for c in checks:
            counts[c["status"]] = counts.get(c["status"], 0) + 1
            info = by_id.setdefault(c["id"], {"text": c["text"], "remediation": c["remediation"], "statuses": {}})
            # A node can run a check id twice only across targets; keep the worst.
            prev = info["statuses"].get(node)
            if prev != "FAIL":
                info["statuses"][node] = c["status"]

    ignore = {e["id"]: e for e in entries}

    def nodes_with(info, status):
        return sorted(n for n, s in info["statuses"].items() if s == status)

    failing, ignored, warn = [], [], []
    for cid in sorted(by_id, key=_id_key):
        info = by_id[cid]
        fail_nodes = nodes_with(info, "FAIL")
        if fail_nodes:
            item = {"id": cid, "text": info["text"], "remediation": info["remediation"], "nodes": fail_nodes}
            if cid in ignore:
                item["entry"] = ignore[cid]
                ignored.append(item)
            else:
                failing.append(item)
        warn_nodes = nodes_with(info, "WARN")
        if warn_nodes:
            warn.append({"id": cid, "text": info["text"], "nodes": warn_nodes})

    stale = []
    for e in entries:
        info = by_id.get(e["id"])
        if info is None:
            seen = "not reported by kube-bench (check the id and the benchmark)"
        elif "FAIL" in info["statuses"].values():
            continue
        else:
            seen = ", ".join("{} on {}".format(s, n) for n, s in sorted(info["statuses"].items()))
        stale.append({"entry": e, "seen": seen})

    expired = expired_entries(entries, today)
    ok = not failing and not expired and not problems and not (fail_on_stale and stale)
    return {
        "ok": ok,
        "counts": counts,
        "failing": failing,
        "ignored": ignored,
        "warn": warn,
        "stale": stale,
        "expired": expired,
        "problems": problems,
        "fail_on_stale": fail_on_stale,
    }


def _indent(text, prefix):
    lines = [l.rstrip() for l in (text or "").strip().splitlines()]
    return "\n".join(prefix + l if l else "" for l in lines)


def _nodes_text(nodes, all_nodes):
    if all_nodes and len(nodes) == len(all_nodes) and len(nodes) > 1:
        return "all nodes"
    return ", ".join(nodes)


def summary(result, header_lines=(), all_nodes=(), ignore_shown="the ignore file"):
    out = list(header_lines)
    c = result["counts"]
    out.append("Results: {} PASS, {} FAIL ({} ignored), {} WARN, {} INFO".format(
        c.get("PASS", 0), c.get("FAIL", 0),
        sum(len(i["nodes"]) for i in result["ignored"]), c.get("WARN", 0), c.get("INFO", 0)))

    for p in result["problems"]:
        out.append("ERROR: " + p)

    if result["failing"]:
        out.append("")
        out.append("FAIL, not in {} ({}):".format(ignore_shown, len(result["failing"])))
        for i in result["failing"]:
            out.append("  {} {}".format(i["id"], i["text"]))
            out.append("    nodes: {}".format(_nodes_text(i["nodes"], all_nodes)))
            if i["remediation"].strip():
                out.append("    remediation:")
                out.append(_indent(i["remediation"], "      "))

    if result["expired"]:
        out.append("")
        out.append("Expired ignore entries ({}):".format(len(result["expired"])))
        for e in result["expired"]:
            out.append("  {}: expired {} -- reason: {}".format(e["id"], e["expires"].isoformat(), e["reason"]))
        out.append("  Review each: fix the check, or extend 'expires' with a current reason.")

    if result["ignored"]:
        out.append("")
        out.append("Ignored FAIL ({}):".format(len(result["ignored"])))
        for i in result["ignored"]:
            e = i["entry"]
            until = " (until {})".format(e["expires"].isoformat()) if e["expires"] else ""
            out.append("  {} {}".format(i["id"], i["text"]))
            out.append("    nodes: {}".format(_nodes_text(i["nodes"], all_nodes)))
            out.append("    reason{}: {}".format(until, e["reason"]))

    if result["stale"]:
        out.append("")
        out.append("Stale ignore entries ({}{}): their check did not FAIL".format(
            len(result["stale"]), ", failing the test (fail_on_stale)" if result["fail_on_stale"] else ""))
        for s in result["stale"]:
            out.append("  {}: {} -- reason: {}".format(s["entry"]["id"], s["seen"], s["entry"]["reason"]))

    if result["warn"]:
        out.append("")
        out.append("WARN ({}; not failing -- manual or unscored checks kube-bench can't decide):".format(
            len(result["warn"])))
        for w in result["warn"]:
            out.append("  {} {}{}".format(
                w["id"], w["text"],
                "" if len(w["nodes"]) == len(all_nodes) else " [{}]".format(", ".join(w["nodes"]))))

    out.append("")
    if result["ok"]:
        out.append("PASS: no FAIL outside {}".format(ignore_shown))
    else:
        why = []
        if result["failing"]:
            why.append("{} failing check(s) not in {}: {}".format(
                len(result["failing"]), ignore_shown, ", ".join(i["id"] for i in result["failing"])))
        if result["expired"]:
            why.append("{} expired ignore entr{}: {}".format(
                len(result["expired"]), "y" if len(result["expired"]) == 1 else "ies",
                ", ".join(e["id"] for e in result["expired"])))
        if result["fail_on_stale"] and result["stale"]:
            why.append("{} stale ignore entr{}: {}".format(
                len(result["stale"]), "y" if len(result["stale"]) == 1 else "ies",
                ", ".join(s["entry"]["id"] for s in result["stale"])))
        why.extend(result["problems"])
        out.append("FAIL: " + "; ".join(why))
    return "\n".join(out) + "\n"


# ---- the cluster -----------------------------------------------------------------------


def _log(msg):
    print("[kube_bench_test] " + msg, flush=True)


def rlocation(path):
    for root in (os.environ.get("RUNFILES_DIR"), os.environ.get("TEST_SRCDIR")):
        if root and os.path.exists(os.path.join(root, path)):
            return os.path.join(root, path)
    manifest = os.environ.get("RUNFILES_MANIFEST_FILE")
    if manifest and os.path.exists(manifest):
        with open(manifest, encoding="utf-8") as f:
            for line in f:
                k, _, v = line.rstrip("\n").partition(" ")
                if k == path:
                    return v
    raise FileNotFoundError("runfile not found: " + path)


def read_env_file(path):
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            k, sep, v = line.rstrip("\n").partition("=")
            if sep:
                env[k] = v
    return env


class Cluster:
    """The kind cluster: an existing one (its env file is there) or one this
    test starts with the kind_cluster's launcher and stops at the end."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.proc = None
        self.env_path = os.path.join(os.environ["TEST_TMPDIR"], cfg["cluster"] + ".env")

    def __enter__(self):
        if os.path.exists(self.env_path):
            _log("using the running cluster {} (env file {})".format(self.cfg["cluster_label"], self.env_path))
        elif os.environ.get("SVCCTL_PORT"):
            raise RuntimeError(
                "running under a rules_itest service_test, but {} has no env file ({}). Add an "
                "itest_service running {} (with its kind_health_check) to the service_test's services, "
                "or run this kube_bench_test on its own.".format(
                    self.cfg["cluster_label"], self.env_path, self.cfg["cluster_label"]))
        else:
            try:
                self._start()
            except BaseException:
                self.__exit__(None, None, None)
                raise
        return read_env_file(self.env_path)

    def _start(self):
        launcher = rlocation(self.cfg["launcher"])
        _log("starting {}".format(self.cfg["cluster_label"]))
        self.proc = subprocess.Popen([launcher])
        # Up to 600 s: includes waiting for a cluster slot (RULES_KIND_MAX_CLUSTERS).
        deadline = time.monotonic() + 600
        while not os.path.exists(self.env_path):
            if self.proc.poll() is not None:
                raise RuntimeError("the kind_cluster launcher exited ({}) before the cluster was ready".format(
                    self.proc.returncode))
            if time.monotonic() > deadline:
                raise RuntimeError("the cluster was not ready within 600 s")
            time.sleep(1)

    def __exit__(self, *exc):
        if self.proc is None or self.proc.poll() is not None:
            return False
        _log("stopping the cluster")
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=300)
        except subprocess.TimeoutExpired:
            _log("the launcher did not exit within 300 s; its reaper deletes the cluster")
        return False


# ---- kube-bench Jobs ----------------------------------------------------------------------

_BEGIN_ERR = "@@KUBE_BENCH_STDERR@@"
_BEGIN_JSON = "@@KUBE_BENCH_JSON rc="
_END = "@@KUBE_BENCH_END@@"

# The script the Job runs: kube-bench's JSON on stdout and its log on stderr,
# framed so `kubectl logs` can be split again.
_JOB_SCRIPT = (
    'kube-bench run --benchmark "$BENCHMARK" --targets "$TARGETS" --json >/tmp/kb.json 2>/tmp/kb.err; '
    'rc=$?; echo "{err}"; cat /tmp/kb.err; echo "{json}$rc@@"; cat /tmp/kb.json; echo; echo "{end}"'
).format(err=_BEGIN_ERR, json=_BEGIN_JSON, end=_END)

# Node paths kube-bench reads (upstream job.yaml, less those a kubeadm/kind
# node doesn't have). `type: Directory`: nothing is created on the node.
_HOST_PATHS = [
    ("/etc/kubernetes", "/etc/kubernetes"),
    ("/var/lib/kubelet", "/var/lib/kubelet"),
    ("/etc/systemd", "/etc/systemd"),
    ("/lib/systemd", "/lib/systemd"),
    ("/usr/bin", "/usr/local/mount-from-host/bin"),
    ("/etc/cni/net.d", "/etc/cni/net.d"),
    ("/opt/cni/bin", "/opt/cni/bin"),
]
_CONTROL_PLANE_PATHS = [("/var/lib/etcd", "/var/lib/etcd")]

_CONTROL_PLANE_LABELS = ("node-role.kubernetes.io/control-plane", "node-role.kubernetes.io/master")


def plan(nodes, targets):
    """nodes: [(name, is_control_plane)] -> [(name, is_cp, [targets])].
    Control-plane nodes run the targets (policies, which is cluster-wide,
    only on the first); workers run `node` if it is a target."""
    out, policies_done = [], False
    for name, cp in sorted(nodes, key=lambda n: (not n[1], n[0])):
        if cp:
            ts = [t for t in targets if t != "policies" or not policies_done]
            policies_done = policies_done or "policies" in ts
        else:
            ts = [t for t in targets if t == "node"]
        if ts:
            out.append((name, cp, ts))
    return out


def job_manifest(name, namespace, node, control_plane, targets, benchmark, image):
    paths = _HOST_PATHS + (_CONTROL_PLANE_PATHS if control_plane else [])
    volumes, mounts = [], []
    for i, (host, mount) in enumerate(paths):
        vol = "host-{}".format(i)
        volumes.append({"name": vol, "hostPath": {"path": host, "type": "Directory"}})
        mounts.append({"name": vol, "mountPath": mount, "readOnly": True})
    return {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {"name": name, "namespace": namespace,
                     "labels": {"app.kubernetes.io/name": "kube-bench", "app.kubernetes.io/managed-by": "rules_kind"}},
        "spec": {
            "backoffLimit": 0,
            "template": {
                "metadata": {"labels": {"app.kubernetes.io/name": "kube-bench", "rules-kind/kube-bench-job": name}},
                "spec": {
                    "hostPID": True,
                    "nodeName": node,
                    "restartPolicy": "Never",
                    "automountServiceAccountToken": False,
                    "tolerations": [{"operator": "Exists"}],
                    "containers": [{
                        "name": "kube-bench",
                        "image": image,
                        # Preloaded by kind_cluster(images = [...]); never pulled.
                        "imagePullPolicy": "Never",
                        "command": ["sh", "-c", _JOB_SCRIPT],
                        "env": [
                            {"name": "BENCHMARK", "value": benchmark},
                            {"name": "TARGETS", "value": ",".join(targets)},
                        ],
                        "volumeMounts": mounts,
                    }],
                    "volumes": volumes,
                },
            },
        },
    }


def split_log(text):
    """-> (rc, stderr, json text). Raises ValueError if the frame is missing."""
    lines = text.splitlines()
    try:
        i_err = lines.index(_BEGIN_ERR)
        i_json = next(i for i, l in enumerate(lines) if l.startswith(_BEGIN_JSON) and l.endswith("@@"))
        i_end = max(i for i, l in enumerate(lines) if l == _END)
    except (ValueError, StopIteration):
        raise ValueError("kube-bench output frame not found")
    rc = int(lines[i_json][len(_BEGIN_JSON):-2])
    return rc, "\n".join(lines[i_err + 1:i_json]), "\n".join(lines[i_json + 1:i_end]).strip()


class Kubectl:
    def __init__(self, env):
        self.bin = env["KUBECTL"]
        self.kubeconfig = env["KUBECONFIG"]

    def run(self, *args, input=None, check=True):
        r = subprocess.run([self.bin, "--kubeconfig", self.kubeconfig] + list(args),
                           input=input, capture_output=True, text=True)
        if check and r.returncode != 0:
            raise RuntimeError("kubectl {} failed ({}):\n{}{}".format(
                " ".join(args), r.returncode, r.stdout, r.stderr))
        return r

    def json(self, *args):
        return json.loads(self.run(*(list(args) + ["-o", "json"])).stdout)


_STUCK = {
    "ErrImageNeverPull": "the kube-bench image is not on node {node}. kind_cluster {cluster} must load it: "
                         "images = [..., \"@rules_kind//:kube_bench_image\"]",
    "InvalidImageName": "invalid image name",
    "CreateContainerConfigError": "cannot create the container",
    "CreateContainerError": "cannot create the container",
    "RunContainerError": "cannot run the container",
}


def run_jobs(kubectl, cfg, deadline_s):
    nodes = []
    for n in kubectl.json("get", "nodes")["items"]:
        labels = n["metadata"].get("labels") or {}
        nodes.append((n["metadata"]["name"], any(l in labels for l in _CONTROL_PLANE_LABELS)))
    work = plan(nodes, cfg["targets"])
    if not work:
        raise RuntimeError("no node to check: targets {} on nodes {}".format(cfg["targets"], nodes))

    ns = "rules-kind-kube-bench-" + secrets.token_hex(3)
    kubectl.run("apply", "-f", "-", input=json.dumps({
        "apiVersion": "v1", "kind": "Namespace",
        "metadata": {"name": ns, "labels": {
            # hostPID + hostPath: allowed even where Pod Security Admission
            # enforces a stricter default.
            "pod-security.kubernetes.io/enforce": "privileged",
            "app.kubernetes.io/managed-by": "rules_kind"}},
    }))
    try:
        return ns, work, _run_jobs_in(kubectl, cfg, ns, work, deadline_s)
    finally:
        if os.environ.get("RULES_KIND_KEEP_CLUSTER", "").lower() in ("", "0", "false", "no"):
            kubectl.run("delete", "namespace", ns, "--wait=false", check=False)
        else:
            _log("RULES_KIND_KEEP_CLUSTER is set: keeping namespace {}".format(ns))


def _run_jobs_in(kubectl, cfg, ns, work, deadline_s):
    # Pods need the namespace's default ServiceAccount to exist.
    deadline = time.monotonic() + 60
    while kubectl.run("get", "serviceaccount", "default", "-n", ns, check=False).returncode != 0:
        if time.monotonic() > deadline:
            raise RuntimeError("namespace {} has no default ServiceAccount after 60 s".format(ns))
        time.sleep(1)

    jobs = {}
    for i, (node, cp, targets) in enumerate(work):
        name = "kube-bench-{}".format(i)
        jobs[name] = node
        _log("{}: kube-bench {} --targets {} ({})".format(
            node, cfg["benchmark"], ",".join(targets), "control plane" if cp else "worker"))
        kubectl.run("apply", "-f", "-", input=json.dumps(
            job_manifest(name, ns, node, cp, targets, cfg["benchmark"], cfg["image"])))

    deadline = time.monotonic() + deadline_s
    done = {}  # job -> pod name
    while len(done) < len(jobs):
        if time.monotonic() > deadline:
            pending = sorted(set(jobs) - set(done))
            details = kubectl.run("describe", "pods", "-n", ns, check=False).stdout
            raise RuntimeError("kube-bench did not finish within {} s on {}:\n{}".format(
                deadline_s, ", ".join(jobs[j] for j in pending), details))
        for pod in kubectl.json("get", "pods", "-n", ns)["items"]:
            job = (pod["metadata"].get("labels") or {}).get("rules-kind/kube-bench-job")
            if job not in jobs or job in done:
                continue
            phase = pod.get("status", {}).get("phase")
            if phase in ("Succeeded", "Failed"):
                done[job] = pod["metadata"]["name"]
                continue
            for cs in pod.get("status", {}).get("containerStatuses") or []:
                waiting = (cs.get("state") or {}).get("waiting") or {}
                reason = waiting.get("reason")
                if reason in _STUCK:
                    raise RuntimeError("{} on node {}: {}: {}".format(
                        reason, jobs[job],
                        _STUCK[reason].format(node=jobs[job], cluster=cfg["cluster_label"]),
                        waiting.get("message", "")))
        if len(done) < len(jobs):
            time.sleep(2)

    reports = []
    for job in sorted(jobs):
        node, pod = jobs[job], done[job]
        log = kubectl.run("logs", "-n", ns, "pod/" + pod).stdout
        try:
            rc, err, text = split_log(log)
        except ValueError:
            raise RuntimeError("kube-bench on node {} produced no result:\n{}".format(node, log))
        if rc != 0 or not text:
            raise RuntimeError("kube-bench on node {} exited {}:\n{}".format(node, rc, err))
        try:
            report = json.loads(text)
        except ValueError as e:
            raise RuntimeError("kube-bench on node {}: output is not JSON ({}):\n{}".format(node, e, text[:2000]))
        reports.append((node, text, report, err))
    return reports


# ---- modes -------------------------------------------------------------------------------


def check_ignore_main(path, shown, stamp):
    try:
        entries = load_ignore(path)
    except IgnoreError as e:
        print("kube-bench ignore file {} is malformed:\n{}".format(shown or path, e), file=sys.stderr)
        return 1
    if stamp:
        with open(stamp, "w") as f:
            f.write("{} entries\n".format(len(entries)))
    return 0


def _header(cfg, work):
    how = "auto for k8s {}".format(cfg["k8s_version"]) if cfg["benchmark_auto"] else "set"
    lines = ["kube-bench {} -- benchmark {} ({}) -- {}".format(
        cfg["kube_bench_version"], cfg["benchmark"], how, cfg["label"])]
    for node, cp, targets in work:
        lines.append("  {} ({}): {}".format(node, "control plane" if cp else "worker", ", ".join(targets)))
    return lines


def run_main(config_path):
    with open(config_path, encoding="utf-8") as f:
        cfg = json.load(f)
    shown = cfg["ignore_shown"] or "the ignore file"

    # A malformed file fails the build already (validation action); this
    # also covers `bazel run` with --norun_validations.
    try:
        entries = load_ignore(rlocation(cfg["ignore"]) if cfg["ignore"] else None)
    except IgnoreError as e:
        print("kube-bench ignore file {} is malformed:\n{}".format(shown, e), file=sys.stderr)
        return 1

    # Bazel's test timeout sends SIGTERM: unwind so the cluster is stopped.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

    with Cluster(cfg) as env:
        kubectl = Kubectl(env)
        _ns, work, reports = run_jobs(kubectl, cfg, cfg.get("job_timeout_s", 300))

    out_dir = os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR")
    if out_dir:
        out_dir = os.path.join(out_dir, "kube-bench")
        os.makedirs(out_dir, exist_ok=True)
        for node, text, _report, err in reports:
            with open(os.path.join(out_dir, node + ".json"), "w", encoding="utf-8") as f:
                f.write(text + "\n")
            if err.strip():
                with open(os.path.join(out_dir, node + ".stderr.txt"), "w", encoding="utf-8") as f:
                    f.write(err + "\n")

    result = evaluate([(n, r) for n, _t, r, _e in reports], entries, utc_today(), cfg["fail_on_stale"])
    text = summary(result, _header(cfg, work), [n for n, _c, _t in work], shown)
    print(text, end="", flush=True)
    if out_dir:
        with open(os.path.join(out_dir, "summary.txt"), "w", encoding="utf-8") as f:
            f.write(text)
        _log("raw kube-bench JSON: {}/<node>.json".format(out_dir))
    return 0 if result["ok"] else 1


def evaluate_main(ignore_path, report_paths, fail_on_stale=False):
    try:
        entries = load_ignore(None if ignore_path == "-" else ignore_path)
    except IgnoreError as e:
        print("kube-bench ignore file {} is malformed:\n{}".format(ignore_path, e), file=sys.stderr)
        return 1
    reports = []
    for p in report_paths:
        with open(p, encoding="utf-8") as f:
            reports.append((os.path.splitext(os.path.basename(p))[0], json.load(f)))
    result = evaluate(reports, entries, utc_today(), fail_on_stale)
    print(summary(result, (), [n for n, _ in reports], ignore_path), end="")
    return 0 if result["ok"] else 1


def main(argv):
    if len(argv) >= 3 and argv[1] == "--run":
        try:
            return run_main(argv[2])
        except (RuntimeError, FileNotFoundError, subprocess.SubprocessError) as e:
            print("kube_bench_test: ERROR: {}".format(e), file=sys.stderr, flush=True)
            return 1
    if len(argv) >= 3 and argv[1] == "--check-ignore":
        args = dict(zip(argv[3::2], argv[4::2]))
        return check_ignore_main(argv[2], args.get("--shown"), args.get("--stamp"))
    if len(argv) >= 4 and argv[1] == "--evaluate":
        return evaluate_main(argv[2], argv[3:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
