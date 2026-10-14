#!/usr/bin/env bash
# Step 1: YAML 1 枚から何が自動生成されるか（KServe）
source "$(dirname "$0")/lib.sh"
delegate_to_operator "$0" "$@"
require_kubeconfig
cd "${REPO_ROOT}"

banner "Step 1: LLMInferenceService を 1 枚 apply する"
run "show_file manifests/step1-baseline.yaml"
run "kubectl apply -f manifests/step1-baseline.yaml"
run "wait_llmisvc_ready sim-baseline 300"

banner "Step 1: KServe が自動生成したリソース"
run "show_tree sim-baseline"
run "kubectl get llmisvc sim-baseline -n ${DEMO_NS} -o jsonpath='{.status.url}{\"\\n\"}'"

banner "Step 1: Gateway 経由で呼んでみる（OpenAI 互換 API）"
run "curl -s ${GATEWAY_URL}/${DEMO_NS}/sim-baseline/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"demo-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":16}' | jq ."
banner "Step 1: どの Pod が返したか（x-inference-pod ヘッダー）"
run "for i in 1 2 3 4 5 6; do curl -s -o /dev/null -D - ${GATEWAY_URL}/${DEMO_NS}/sim-baseline/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"demo-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":4}' | grep -i x-inference-pod; done"
