#!/usr/bin/env bash
# terraform/ から OCI Resource Manager 用の stack.zip を作る。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${REPO_ROOT}/stack.zip}"
rm -f "${OUT}"
cd "${REPO_ROOT}/terraform"
# tfvars / state / .terraform は含めない（シークレット混入防止）
zip -q -X "${OUT}" ./*.tf schema.yaml
echo "${OUT}"
