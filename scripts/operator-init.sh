#!/usr/bin/env bash
# operator 上で実行: インスタンス・プリンシパルで kubeconfig を作り、ノード Ready を待つ。
#   bash scripts/operator-init.sh <cluster_id>   （10-infra-up.sh から呼ばれる）
source "$(dirname "$0")/lib.sh"
[[ "${ON_OPERATOR}" == "1" ]] || die "operator 上で実行してください"
need oci kubectl
CLUSTER_ID="${1:?cluster_id を指定してください}"

# 動的グループ / ポリシーは作成直後に反映されないことがあるので、成功するまで再試行する
gen_kubeconfig() {
  rm -f "${KUBECONFIG}"
  oci ce cluster create-kubeconfig \
    --cluster-id "${CLUSTER_ID}" \
    --file "${KUBECONFIG}" \
    --token-version 2.0.0 \
    --kube-endpoint PRIVATE_ENDPOINT \
    --auth instance_principal >/dev/null &&
    chmod 600 "${KUBECONFIG}" &&
    kubectl get --raw /version
}
wait_until 600 "kubeconfig 生成（インスタンス・プリンシパル）と API 疎通" gen_kubeconfig

EXPECTED_NODES="${WORKER_COUNT:-3}"
ready_nodes() {
  [[ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')" -ge "${EXPECTED_NODES}" ]]
}
wait_until 900 "${EXPECTED_NODES} ノード Ready" ready_nodes
kubectl get nodes -o wide
