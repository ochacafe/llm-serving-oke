#!/usr/bin/env bash
# デモ用リソース（LLMInferenceService）だけ消して Step 1 前の状態に戻す
source "$(dirname "$0")/lib.sh"
need kubectl
require_kubeconfig
info "llm-demo の LLMInferenceService を削除します"
kubectl delete llminferenceservice --all -n "${DEMO_NS}" --wait=true --timeout=180s || true
no_pods() { [[ -z "$(kubectl get pods -n "${DEMO_NS}" --no-headers 2>/dev/null)" ]]; }
wait_until 300 "llm-demo の Pod がすべて消えた" no_pods
