#!/usr/bin/env python3
"""Checks that the images pinned for a chart match the chart version (docs/adr/021). Needs network.

cert-manager and the Barman Cloud plugin ship CRDs and RBAC in the chart that belong to one image
version. Their images are pinned in kubernetes/values, apart from the chart version, and Renovate may
see one release before the other: this is what keeps half an update from merging.
"""
import pathlib
import subprocess
import sys

import yaml

KUBERNETES = pathlib.Path(__file__).resolve().parent.parent / "kubernetes"
# chart key in apps/values.yaml: (values file, paths of the image blocks in it)
COUPLED = {
    "certManager": (
        "cert-manager.yaml",
        [("image",), ("webhook", "image"), ("cainjector", "image"), ("startupapicheck", "image")],
    ),
    "barmanCloudPlugin": ("barman-cloud-plugin.yaml", [("image",), ("sidecarImage",)]),
}


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def app_version(chart):
    command = ["helm", "show", "chart", chart["chart"], "--repo", chart["repoURL"], "--version", str(chart["version"])]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return str(yaml.safe_load(result.stdout)["appVersion"])


def main():
    charts = load(KUBERNETES / "apps/values.yaml")["charts"]
    errors, total = [], 0
    for key, (values_file, paths) in COUPLED.items():
        expected = app_version(charts[key])
        values = load(KUBERNETES / "values" / values_file)
        for path in paths:
            block = values
            for name in path:
                block = block[name]
            total += 1
            tag = str(block.get("tag", "")).split("@")[0]
            if tag != expected:
                errors.append(
                    f"kubernetes/values/{values_file}: {'.'.join(path)}.tag is '{tag}', but chart "
                    f"{charts[key]['chart']} {charts[key]['version']} is built for '{expected}'"
                )
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"OK: {total} images match their chart version")
    return 0


if __name__ == "__main__":
    sys.exit(main())
