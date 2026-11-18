"""pytest plugin: deselects the ceph/s3-tests tests z3 leaves out.

Loaded with `-p s3tests_subset` (this directory on PYTHONPATH). Reads
s3tests-exclude.txt next to it: one `test_name<TAB>reason` per line (the
name without parameters, so every parametrization goes), `#` comments.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))


def load(path=os.path.join(HERE, "s3tests-exclude.txt")):
    names = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            name, _, reason = line.partition("\t")
            names[name.strip()] = reason.strip()
    return names


def pytest_collection_modifyitems(config, items):
    excluded = load()
    keep, drop = [], []
    for item in items:
        base = item.name.split("[", 1)[0]
        (drop if base in excluded else keep).append(item)
    if drop:
        config.hook.pytest_deselected(items=drop)
        items[:] = keep
