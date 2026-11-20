#!/usr/bin/env python3
"""Validates the Grafana alert rules versioned in base/alerts/*.yaml.

Checks what provisioning only complains about at runtime (and the e2e takes a while to show):
a unique uid across all files, a known severity (the notification policy routes
on it), a known datasource and the expected A (query) + B (threshold) pair.
"""
import pathlib
import sys

import yaml

ALERTS = pathlib.Path(__file__).resolve().parent.parent / "kubernetes/workloads/observability/base/alerts"
SEVERITIES = {"critical", "warning", "info"}
DATASOURCES = {"prometheus", "loki"}
NODATA = {"OK", "Alerting", "NoData"}


def main():
    errors, uids, total = [], {}, 0
    for path in sorted(ALERTS.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for group in doc.get("groups", []):
            for rule in group.get("rules", []):
                total += 1
                uid = rule.get("uid", "?")
                where = f"{path.name}:{uid}"
                if uid in uids:
                    errors.append(f"{where}: duplicate uid (already in {uids[uid]})")
                uids[uid] = path.name
                if rule.get("labels", {}).get("severity") not in SEVERITIES:
                    errors.append(f"{where}: severity must be one of {sorted(SEVERITIES)}")
                if rule.get("noDataState") not in NODATA:
                    errors.append(f"{where}: invalid noDataState")
                data = {d["refId"]: d for d in rule.get("data", [])}
                a, b = data.get("A"), data.get("B")
                if rule.get("condition") != "B" or not a or not b:
                    errors.append(f"{where}: expected condition B with queries A and B")
                    continue
                if a["datasourceUid"] not in DATASOURCES:
                    errors.append(f"{where}: unknown datasourceUid {a['datasourceUid']}")
                if not a["model"].get("expr"):
                    errors.append(f"{where}: A without expr")
                if b["datasourceUid"] != "__expr__" or b["model"].get("type") != "threshold":
                    errors.append(f"{where}: B must be a threshold on __expr__")
    for err in errors:
        print(err, file=sys.stderr)
    print(f"{total} rules in {len(list(ALERTS.glob('*.yaml')))} files: {'ERRORS' if errors else 'ok'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
