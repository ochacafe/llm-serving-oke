#!/usr/bin/env bash
# Step 3: prefill を書き足して P/D 分離
#   ログは別ペインで: bash scripts/demo-step3.sh logs
source "$(dirname "$0")/lib.sh"
require_kubeconfig
cd "${REPO_ROOT}"

LOG_PATTERN='EPP received request|"Received"|Finished processing'

if [[ "${1:-}" == "logs" ]]; then
  banner "sim-pd のログ（Prefill / Decode / routing sidecar）"
  follow_logs sim-pd "${LOG_PATTERN}"
  exit 0
fi

banner "Step 3: Step 2 との差分は prefill: を書き足しただけ"
run "show_diff manifests/step2-llmd.yaml manifests/step3-pd.yaml"
run "kubectl apply -f manifests/step3-pd.yaml"
run "wait_llmisvc_ready sim-pd 300"

banner "Step 3: Prefill Pod と Decode Pod が分かれている"
run "kubectl get pods -n ${DEMO_NS} -l app.kubernetes.io/name=sim-pd -L llm-d.ai/role"

banner "Step 3: Decode Pod には routing sidecar が自動で注入されている"
run "kubectl get pods -n ${DEMO_NS} -l app.kubernetes.io/name=sim-pd,llm-d.ai/role=decode -o custom-columns='POD:.metadata.name,SIDECAR(initContainers):.spec.initContainers[*].name,CONTAINERS:.spec.containers[*].name'"

banner "Step 3: 1 リクエストが Prefill Pod → Decode Pod とリレーされる"
log "別ペインで: bash scripts/demo-step3.sh logs"
open_url "${GRAFANA_URL}/d/pd"
ensure_loadgen
run "loadgen single --target ${LOADGEN_GATEWAY_URL}/${DEMO_NS}/sim-pd --prompt-tokens 3000 --count ${PD_SINGLE_COUNT:-3}"

banner "Step 3: Prefill だけ増やす（入力が長いワークロードは Prefill だけ増強）"
run "kubectl patch llmisvc sim-pd -n ${DEMO_NS} --type merge -p '{\"spec\":{\"prefill\":{\"replicas\":4}}}'"
run "kubectl rollout status deploy/sim-pd-kserve-prefill -n ${DEMO_NS} --timeout=180s"
run "kubectl get pods -n ${DEMO_NS} -l app.kubernetes.io/name=sim-pd -L llm-d.ai/role"
