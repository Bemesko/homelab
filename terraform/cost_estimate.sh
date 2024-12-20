#!/usr/bin/env bash
set -xeuo pipefail

terraform plan -out=plan.tfplan >/dev/null &&
  terraform show -json plan.tfplan |
  curl -s -X POST -H "Content-Type: application/json" -d @- https://cost.modules.tf/
