#!/usr/bin/env bash
# Step 2: 普通の L7 LB（P2C） vs llm-d のスケジューラ（prefix cache 考慮）
#   LOADGEN_DURATION=300 LOADGEN_RPS=4 で負荷を調整
source "$(dirname "$0")/lib.sh"
delegate_to_operator "$0" "$@"
require_kubeconfig
cd "${REPO_ROOT}"

banner "Step 2: Step 1 との差分は scheduler を足しただけ"
run "show_diff manifests/step1-baseline.yaml manifests/step2-llmd.yaml"
run "kubectl apply -f manifests/step2-llmd.yaml"
run "wait_llmisvc_ready sim-llmd 300"

banner "Step 2: InferencePool と EPP（*-kserve-router-scheduler）が増えた"
run "show_tree sim-llmd"
run "kubectl get inferencepools.inference.networking.k8s.io,deploy -n ${DEMO_NS}"

banner "Step 2: 同じ負荷を両方に流して比較（Grafana: ${GRAFANA_URL}/d/routing）"
open_url "${GRAFANA_URL}/d/routing"
ensure_loadgen
pause "[Enter で負荷開始] 最初の 30 秒は両方とも冷えていて差が出ない → 1 分ほどで差が開く"
run "loadgen compare \
  --target baseline=${LOADGEN_GATEWAY_URL}/${DEMO_NS}/sim-baseline \
  --target llmd=${LOADGEN_GATEWAY_URL}/${DEMO_NS}/sim-llmd \
  --tenants ${LOADGEN_TENANTS:-10} --prompt-tokens ${LOADGEN_PROMPT_TOKENS:-4000} \
  --rps ${LOADGEN_RPS:-4} --duration ${LOADGEN_DURATION:-300} --max-tokens 64 \
  --out-dir ${LOADGEN_OUT_DIR} ${LOADGEN_EXTRA:-}"
