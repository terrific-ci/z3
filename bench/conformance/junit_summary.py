"""Summarizes a pytest JUnit XML file from ceph/s3-tests.

usage: junit_summary.py <results.xml> [--fails] [--list-passed FILE]

Prints pass/fail/error/skip counts; with --fails, every failing test with
the first line of its message, grouped by message.
"""
import collections
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
show_fails = "--fails" in sys.argv
passed_out = sys.argv[sys.argv.index("--list-passed") + 1] if "--list-passed" in sys.argv else None

root = ET.parse(path).getroot()
counts = collections.Counter()
fails = []
passed = []
for case in root.iter("testcase"):
    name = case.get("name")
    status = "passed"
    msg = ""
    for kind in ("failure", "error", "skipped"):
        el = case.find(kind)
        if el is not None:
            status = kind
            msg = (el.get("message") or el.text or "").strip().splitlines()[0][:200] if (el.get("message") or el.text) else ""
            break
    counts[status] += 1
    if status in ("failure", "error"):
        fails.append((name, status, msg))
    elif status == "passed":
        passed.append(name)

print(" ".join(f"{k}={counts[k]}" for k in ("passed", "failure", "error", "skipped")))
if show_fails:
    groups = collections.defaultdict(list)
    for name, status, msg in fails:
        groups[(status, msg)].append(name)
    for (status, msg), names in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print(f"\n[{status}] x{len(names)} {msg}")
        for n in names:
            print(f"    {n}")
if passed_out:
    with open(passed_out, "w") as f:
        f.write("\n".join(sorted(passed)) + "\n")
