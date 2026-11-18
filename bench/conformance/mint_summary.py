"""Summarizes a MinIO Mint log.json and checks it against the exclusions.

usage: mint_summary.py <log.json> <mint-exclude.txt>

Prints PASS/FAIL/NA counts per SDK suite and every failure. A failure is
expected when a line of the exclusion file (`suite<TAB>pattern<TAB>reason`)
starts the entry name and the pattern occurs in "name :: function" (`*`: any;
`NO-RESULTS`: the suite may log no result at all). Exits 1 when an
unexpected failure remains, or when a suite produced no result at all.
"""
import collections
import json
import sys

log_path, exclude_path = sys.argv[1], sys.argv[2]

exclusions = []
for line in open(exclude_path, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    suite, func, reason = (line.split("\t") + ["", ""])[:3]
    exclusions.append((suite.strip(), func.strip(), reason.strip()))

SUITES = ["aws-sdk-go-v2", "aws-sdk-java-v2", "aws-sdk-php", "aws-sdk-ruby", "awscli", "healthcheck", "mc",
          "minio-go", "minio-java", "minio-js", "minio-py", "s3cmd", "s3select", "versioning"]


def suite_of(name):
    for s in sorted(SUITES, key=len, reverse=True):
        if name.startswith(s):
            return s
    return name


counts = collections.defaultdict(collections.Counter)
unexpected, expected = [], []


def entries(text):
    """Every JSON object in the log, one per line or pretty-printed."""
    dec = json.JSONDecoder()
    i = 0
    while True:
        i = text.find("{", i)
        if i < 0:
            return
        try:
            obj, end = dec.raw_decode(text, i)
        except ValueError:
            i += 1
            continue
        if isinstance(obj, dict) and "name" in obj:
            yield obj
        i = end


for e in entries(open(log_path, encoding="utf-8", errors="replace").read()):
    name = e.get("name") or ""
    suite = suite_of(name)
    status = e.get("status") or "?"
    func = (e.get("function") or "").strip()
    label = f"{name} :: {func}" if func else name
    if status == "FAIL":
        hit = next((x for x in exclusions if name.startswith(x[0]) and (x[1] == "*" or x[1] in label)), None)
        if hit:
            counts[suite]["EXCLUDED"] += 1
            expected.append((label, hit[2]))
            continue
        msg = str(e.get("error") or e.get("message") or "")[:300].replace("\n", " ")
        unexpected.append((label, msg))
    counts[suite][status] += 1

total = collections.Counter()
print(f"{'suite':18} {'PASS':>5} {'FAIL':>5} {'NA':>5} {'EXCL':>5}")
for s in SUITES:
    c = counts.get(s, collections.Counter())
    total.update(c)
    print(f"{s:18} {c['PASS']:5} {c['FAIL']:5} {c['NA']:5} {c['EXCLUDED']:5}")
print(f"{'total':18} {total['PASS']:5} {total['FAIL']:5} {total['NA']:5} {total['EXCLUDED']:5}")
missing = [s for s in SUITES if s not in counts and not any(x[0] == s and x[1] == "NO-RESULTS" for x in exclusions)]
def grouped(rows):
    """(row, count) in first-seen order, repeats folded."""
    seen = collections.OrderedDict()
    for r in rows:
        seen[r] = seen.get(r, 0) + 1
    return seen.items()


if expected:
    print("\nexcluded failures:")
    for (label, reason), n in grouped(expected):
        print(f"  - {label}{f' (x{n})' if n > 1 else ''}  ({reason})")
if unexpected:
    print("\nUNEXPECTED failures:")
    for (label, msg), n in grouped((label, msg[:160]) for label, msg in unexpected):
        print(f"  - {label}{f' (x{n})' if n > 1 else ''}\n      {msg}")
if missing:
    print("\nsuites without results: " + ", ".join(missing))
sys.exit(1 if unexpected or missing else 0)
