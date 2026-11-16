"""Unit tests for private/kube_bench.py: the ignore file, the result logic,
the summary and the Job spec. No cluster: the kube-bench JSON is checked in,
from a run on a 2-node kind cluster (k8s 1.35, cis-1.12, kube-bench 0.16.0):
tests/kube_bench/control-plane.json and worker.json.

Usage: kube_bench_unit_test.py <kube_bench.py> <control-plane.json> <worker.json> <kind_ignore.yaml>
"""

import copy
import datetime
import importlib.util
import json
import os
import sys
import tempfile
import unittest

KB_PATH, SAMPLE_PATH, WORKER_PATH, KIND_IGNORE_PATH = sys.argv[1:5]
del sys.argv[1:5]

_spec = importlib.util.spec_from_file_location("kube_bench", KB_PATH)
kb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(kb)

with open(SAMPLE_PATH, encoding="utf-8") as f:
    SAMPLE = json.load(f)
with open(WORKER_PATH, encoding="utf-8") as f:
    WORKER = json.load(f)
with open(KIND_IGNORE_PATH, encoding="utf-8") as f:
    KIND_IGNORE = f.read()

TODAY = datetime.date(2026, 11, 16)

# The FAILs a stock kind control-plane node reports (cis-1.12).
KIND_FAILS = ["1.1.12", "1.2.5", "1.2.15", "1.2.16", "1.2.17", "1.2.18", "1.2.19",
              "1.2.30", "1.3.2", "1.4.1", "4.1.1", "4.1.9"]


def worker_report():
    return copy.deepcopy(WORKER)


def entry(cid, reason="because", expires=None):
    return {"id": cid, "reason": reason, "expires": expires}


class IgnoreFileTest(unittest.TestCase):
    def problems(self, text):
        with self.assertRaises(kb.IgnoreError) as cm:
            kb.parse_ignore(text)
        return str(cm.exception)

    def test_kind_ignore_file_is_valid(self):
        entries = kb.parse_ignore(KIND_IGNORE)
        self.assertEqual([e["id"] for e in entries], KIND_FAILS)
        self.assertTrue(all(e["reason"] for e in entries))

    def test_minimal_and_optional_expires(self):
        entries = kb.parse_ignore(
            "checks:\n"
            "  - id: 1.2.15   # plain scalar stays a string\n"
            "    reason: 'profiling: on'\n"
            "  - id: \"2.1\"\n"
            "    reason: etcd\n"
            "    expires: 2027-01-31\n")
        self.assertEqual(entries, [
            entry("1.2.15", "profiling: on"),
            entry("2.1", "etcd", datetime.date(2027, 1, 31)),
        ])

    def test_empty_file_and_empty_list(self):
        self.assertEqual(kb.parse_ignore(""), [])
        self.assertEqual(kb.parse_ignore("# nothing\n"), [])
        self.assertEqual(kb.parse_ignore("checks: []\n"), [])
        self.assertEqual(kb.parse_ignore("checks:\n"), [])

    def test_missing_reason_and_id(self):
        p = self.problems("checks:\n  - id: 1.2.15\n  - reason: x\n")
        self.assertIn("checks[0] (1.2.15): 'reason' is missing or empty", p)
        self.assertIn("checks[1]: 'id' is missing or empty", p)

    def test_empty_reason(self):
        p = self.problems("checks:\n  - id: 1.2.15\n    reason: ''\n")
        self.assertIn("'reason' is missing or empty", p)

    def test_unknown_keys_with_hints(self):
        p = self.problems(
            "checks:\n  - id: 1.2.15\n    statement: x\n    expired_at: 2027-01-01\n")
        self.assertIn("unknown key 'statement' -- the reason goes in 'reason'", p)
        self.assertIn("unknown key 'expired_at' -- the expiry goes in 'expires'", p)
        self.assertIn("'reason' is missing or empty", p)

    def test_unknown_top_level_key(self):
        p = self.problems("ignore:\n  - id: 1.2.15\n    reason: x\n")
        self.assertIn("unknown key 'ignore' -- the entries go under 'checks:'", p)

    def test_bad_id_duplicate_and_date(self):
        p = self.problems(
            "checks:\n"
            "  - id: KSV-0017\n    reason: x\n"
            "  - id: 1.2.15\n    reason: x\n"
            "  - id: 1.2.15\n    reason: y\n"
            "  - id: 1.3.2\n    reason: x\n    expires: 2027-02-30\n"
            "  - id: 1.4.1\n    reason: x\n    expires: next year\n")
        self.assertIn("id 'KSV-0017' is not a check id such as 1.2.15", p)
        self.assertIn("checks[2] (1.2.15): id 1.2.15 is already listed at checks[1]", p)
        self.assertIn("expires '2027-02-30' is not a date (YYYY-MM-DD)", p)
        self.assertIn("expires 'next year' is not a date", p)

    def test_shape_errors(self):
        self.assertIn("expected a mapping with a `checks:` list", self.problems("- id: 1.2.15\n"))
        self.assertIn("checks: expected a list", self.problems("checks: 1.2.15\n"))
        self.assertIn("expected a mapping with id and reason", self.problems("checks:\n  - 1.2.15\n"))

    def test_unsupported_yaml_by_line(self):
        self.assertIn("line 3: unsupported YAML ('>')",
                      self.problems("checks:\n  - id: 1.2.15\n    reason: >-\n      folded\n"))
        self.assertIn("line 2: tab in indentation", self.problems("checks:\n\t- id: 1.2.15\n"))
        self.assertIn("line 4: duplicate key 'reason'",
                      self.problems("checks:\n  - id: 1.2.15\n    reason: a\n    reason: b\n"))

    def test_every_problem_is_listed(self):
        p = self.problems("checks:\n  - id: x\n  - id: 1.1\n    because: y\n")
        self.assertEqual(len(p.splitlines()), 4, p)

    def test_expiry_boundary(self):
        es = [entry("1", expires=datetime.date(2026, 11, 16)),
              entry("2", expires=datetime.date(2026, 11, 17)),
              entry("3")]
        # An entry expires at the start of its day (UTC).
        self.assertEqual([e["id"] for e in kb.expired_entries(es, TODAY)], ["1"])

    def test_check_ignore_main(self):
        with tempfile.TemporaryDirectory() as d:
            good, bad, stamp = (os.path.join(d, n) for n in ("good.yaml", "bad.yaml", "ok"))
            with open(good, "w") as f:
                f.write(KIND_IGNORE)
            with open(bad, "w") as f:
                f.write("checks:\n  - id: 1.2.15\n")
            self.assertEqual(kb.check_ignore_main(good, "good.yaml", stamp), 0)
            self.assertTrue(os.path.exists(stamp))
            self.assertEqual(kb.check_ignore_main(bad, "bad.yaml", None), 1)
            # An expired entry is not a build-time error: the date isn't an input.
            with open(good, "w") as f:
                f.write("checks:\n  - id: 1.2.15\n    reason: x\n    expires: 2000-01-01\n")
            self.assertEqual(kb.check_ignore_main(good, "good.yaml", None), 0)


class EvaluateTest(unittest.TestCase):
    def kind_entries(self):
        return kb.parse_ignore(KIND_IGNORE)

    def test_worker_runs_node_checks_only(self):
        r = kb.evaluate([("worker", WORKER)], [], TODAY)
        self.assertEqual(r["counts"], {"PASS": 17, "FAIL": 2, "WARN": 6, "INFO": 0})
        self.assertEqual([i["id"] for i in r["failing"]], ["4.1.1", "4.1.9"])

    def test_sample_counts(self):
        r = kb.evaluate([("cp", SAMPLE)], [], TODAY)
        self.assertEqual(r["counts"], {"PASS": 63, "FAIL": 12, "WARN": 56, "INFO": 0})
        self.assertEqual([i["id"] for i in r["failing"]], KIND_FAILS)
        self.assertFalse(r["ok"])

    def test_kind_ignore_passes_the_sample(self):
        r = kb.evaluate([("cp", SAMPLE)], self.kind_entries(), TODAY)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["failing"], [])
        self.assertEqual([i["id"] for i in r["ignored"]], KIND_FAILS)
        self.assertEqual(r["stale"], [])

    def test_unlisted_fail_fails(self):
        entries = [e for e in self.kind_entries() if e["id"] != "1.2.15"]
        r = kb.evaluate([("cp", SAMPLE)], entries, TODAY)
        self.assertFalse(r["ok"])
        self.assertEqual([i["id"] for i in r["failing"]], ["1.2.15"])
        self.assertIn("--profiling=false", r["failing"][0]["remediation"])
        self.assertEqual(r["failing"][0]["nodes"], ["cp"])

    def test_expired_entry_fails_even_though_it_matches(self):
        entries = self.kind_entries()
        entries[0]["expires"] = datetime.date(2020, 1, 1)
        r = kb.evaluate([("cp", SAMPLE)], entries, TODAY)
        self.assertFalse(r["ok"])
        self.assertEqual(r["failing"], [])
        self.assertEqual([e["id"] for e in r["expired"]], ["1.1.12"])

    def test_unexpired_entry_passes(self):
        entries = self.kind_entries()
        entries[0]["expires"] = datetime.date(2027, 1, 1)
        self.assertTrue(kb.evaluate([("cp", SAMPLE)], entries, TODAY)["ok"])

    def test_stale_entries(self):
        entries = self.kind_entries() + [entry("1.1.1"), entry("1.1.9"), entry("9.9.9")]
        r = kb.evaluate([("cp", SAMPLE)], entries, TODAY)
        self.assertTrue(r["ok"])  # stale entries are listed, not failing
        seen = {s["entry"]["id"]: s["seen"] for s in r["stale"]}
        self.assertEqual(seen["1.1.1"], "PASS on cp")
        self.assertEqual(seen["1.1.9"], "WARN on cp")
        self.assertIn("not reported by kube-bench", seen["9.9.9"])
        r = kb.evaluate([("cp", SAMPLE)], entries, TODAY, fail_on_stale=True)
        self.assertFalse(r["ok"])

    def test_warn_never_fails(self):
        r = kb.evaluate([("cp", SAMPLE)], self.kind_entries(), TODAY)
        self.assertTrue(r["ok"])
        self.assertEqual(len(r["warn"]), 56)
        self.assertIn("5.2.3", [w["id"] for w in r["warn"]])

    def test_two_nodes_merge_by_id(self):
        reports = [("cp", SAMPLE), ("worker", worker_report())]
        r = kb.evaluate(reports, [e for e in self.kind_entries() if e["id"] != "4.1.1"], TODAY)
        self.assertEqual(r["failing"][0]["id"], "4.1.1")
        self.assertEqual(r["failing"][0]["nodes"], ["cp", "worker"])
        ignored = {i["id"]: i["nodes"] for i in r["ignored"]}
        self.assertEqual(ignored["4.1.9"], ["cp", "worker"])
        self.assertEqual(ignored["1.2.15"], ["cp"])

    def test_a_fail_on_one_node_is_a_fail(self):
        worker = worker_report()
        for c in worker["Controls"]:
            for t in c["tests"]:
                for res in t["results"]:
                    if res["test_number"] == "4.1.1":
                        res["status"] = "PASS"
        entries = [e for e in self.kind_entries() if e["id"] != "4.1.1"]
        r = kb.evaluate([("cp", SAMPLE), ("worker", worker)], entries, TODAY)
        self.assertEqual([(i["id"], i["nodes"]) for i in r["failing"]], [("4.1.1", ["cp"])])

    def test_empty_report_is_an_error(self):
        r = kb.evaluate([("cp", SAMPLE), ("worker", {"Controls": []})], self.kind_entries(), TODAY)
        self.assertFalse(r["ok"])
        self.assertEqual(r["problems"], ["kube-bench reported no checks on node worker"])


class SummaryTest(unittest.TestCase):
    def test_failing_ignored_stale_expired_warn(self):
        entries = [e for e in kb.parse_ignore(KIND_IGNORE) if e["id"] != "1.2.15"]
        entries[0]["expires"] = datetime.date(2020, 1, 1)
        entries.append(entry("1.1.1", "stale one"))
        r = kb.evaluate([("cp", SAMPLE)], entries, TODAY)
        s = kb.summary(r, ["header"], ["cp"], "x.yaml")
        self.assertTrue(s.startswith("header\nResults: 63 PASS, 12 FAIL (11 ignored), 56 WARN, 0 INFO\n"), s)
        self.assertIn("FAIL, not in x.yaml (1):\n  1.2.15 Ensure that the --profiling argument is set to false", s)
        self.assertIn("    remediation:\n      Edit the API server pod specification file", s)
        self.assertIn("Expired ignore entries (1):\n  1.1.12: expired 2020-01-01 -- reason: kubeadm runs etcd", s)
        self.assertIn("Ignored FAIL (11):", s)
        self.assertIn("    reason (until 2020-01-01): kubeadm runs etcd as root", s)
        self.assertIn("Stale ignore entries (1): their check did not FAIL\n  1.1.1: PASS on cp -- reason: stale one", s)
        self.assertIn("WARN (56; not failing", s)
        self.assertTrue(s.endswith(
            "FAIL: 1 failing check(s) not in x.yaml: 1.2.15; 1 expired ignore entry: 1.1.12\n"), s)

    def test_pass_line(self):
        r = kb.evaluate([("cp", SAMPLE)], kb.parse_ignore(KIND_IGNORE), TODAY)
        self.assertTrue(kb.summary(r, (), ["cp"], "x.yaml").endswith("PASS: no FAIL outside x.yaml\n"))


class JobTest(unittest.TestCase):
    def test_plan(self):
        targets = ["master", "controlplane", "etcd", "node", "policies"]
        self.assertEqual(kb.plan([("w1", False), ("cp2", True), ("cp1", True)], targets), [
            ("cp1", True, targets),
            ("cp2", True, ["master", "controlplane", "etcd", "node"]),
            ("w1", False, ["node"]),
        ])
        # Without `node`, workers have nothing to run.
        self.assertEqual(kb.plan([("cp", True), ("w", False)], ["master"]), [("cp", True, ["master"])])

    def test_job_manifest(self):
        cp = kb.job_manifest("kube-bench-0", "ns", "n1", True, ["master", "node"], "cis-1.12", "img:tag")
        spec = cp["spec"]["template"]["spec"]
        self.assertTrue(spec["hostPID"])
        self.assertEqual(spec["nodeName"], "n1")
        self.assertEqual(spec["tolerations"], [{"operator": "Exists"}])
        self.assertFalse(spec["automountServiceAccountToken"])
        c = spec["containers"][0]
        self.assertEqual((c["image"], c["imagePullPolicy"]), ("img:tag", "Never"))
        self.assertEqual({e["name"]: e["value"] for e in c["env"]},
                         {"BENCHMARK": "cis-1.12", "TARGETS": "master,node"})
        paths = {v["hostPath"]["path"] for v in spec["volumes"]}
        self.assertTrue({"/etc/kubernetes", "/var/lib/kubelet", "/etc/systemd", "/var/lib/etcd"} <= paths)
        self.assertTrue(all(v["hostPath"]["type"] == "Directory" for v in spec["volumes"]))
        self.assertTrue(all(m["readOnly"] for m in c["volumeMounts"]))
        worker = kb.job_manifest("kube-bench-1", "ns", "n2", False, ["node"], "cis-1.12", "img:tag")
        self.assertNotIn("/var/lib/etcd", {v["hostPath"]["path"] for v in worker["spec"]["template"]["spec"]["volumes"]})

    def test_split_log(self):
        log = "\n".join([kb._BEGIN_ERR, "Warning: x", kb._BEGIN_JSON + "0@@", '{"Controls": []}', "", kb._END])
        self.assertEqual(kb.split_log(log), (0, "Warning: x", '{"Controls": []}'))
        with self.assertRaises(ValueError):
            kb.split_log("exec format error")


class ClusterTest(unittest.TestCase):
    CFG = {"cluster": "k8s", "cluster_label": "//app:k8s", "launcher": "_main/app/k8s_kind_cluster.sh"}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.saved = {k: os.environ.get(k) for k in ("TEST_TMPDIR", "SVCCTL_PORT")}
        os.environ["TEST_TMPDIR"] = self.tmp.name
        os.environ.pop("SVCCTL_PORT", None)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def test_uses_an_existing_env_file(self):
        with open(os.path.join(self.tmp.name, "k8s.env"), "w") as f:
            f.write("KUBECONFIG=/x/kubeconfig\nKUBECTL=/x/kubectl\nKIND_CLUSTER_NAME=kind-1\n")
        c = kb.Cluster(self.CFG)
        with c as env:
            self.assertEqual(env["KUBECTL"], "/x/kubectl")
        self.assertIsNone(c.proc)  # nothing started, nothing to stop

    def test_service_test_without_the_cluster_service(self):
        os.environ["SVCCTL_PORT"] = "1234"
        with self.assertRaises(RuntimeError) as cm:
            with kb.Cluster(self.CFG):
                pass
        self.assertIn("running under a rules_itest service_test, but //app:k8s has no env file", str(cm.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
