#!/usr/bin/env python3
"""KSOPS stand-in for offline validation (pre-commit and CI, without an age key).

Receives the kustomize ResourceList (exec KRM function), reads each file in the
generator's `files` and returns the resource with the values replaced by a
placeholder. It validates the structure (kubeconform/kube-linter), never the values.
Fails if any file is not encrypted by SOPS.
"""

import base64
import sys

import yaml

PLACEHOLDER = "ksops-stub"


def stub_values(values, encode):
    placeholder = base64.b64encode(PLACEHOLDER.encode()).decode() if encode else PLACEHOLDER
    return {key: placeholder for key in (values or {})}


def main():
    resource_list = yaml.safe_load(sys.stdin)
    items = list(resource_list.get("items") or [])
    for path in resource_list["functionConfig"].get("files", []):
        with open(path, encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
        if not isinstance(doc, dict) or "sops" not in doc:
            sys.exit(f"ksops-stub: {path} is not encrypted by SOPS")
        del doc["sops"]
        if "data" in doc:
            doc["data"] = stub_values(doc["data"], encode=True)
        if "stringData" in doc:
            doc["stringData"] = stub_values(doc["stringData"], encode=False)
        items.append(doc)
    resource_list["items"] = items
    yaml.safe_dump(resource_list, sys.stdout, sort_keys=False)


if __name__ == "__main__":
    main()
