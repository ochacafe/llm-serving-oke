#!/usr/bin/env bash
# 締め: Step1 → 2 → 3 の YAML 差分
source "$(dirname "$0")/lib.sh"
cd "${REPO_ROOT}"
banner "Step 1 → Step 2: scheduler を足すと llm-d のスケジューラ"
run "show_diff manifests/step1-baseline.yaml manifests/step2-llmd.yaml"
banner "Step 2 → Step 3: prefill を足すと P/D 分離"
run "show_diff manifests/step2-llmd.yaml manifests/step3-pd.yaml"
banner "単体の vLLM 相当から P/D 分離クラスタまで、この差分だけ"
