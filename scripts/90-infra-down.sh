#!/usr/bin/env bash
# ORM の Destroy ジョブで OKE / VCN を削除し、スタックも削除する。
#   bash scripts/90-infra-down.sh          # 確認あり
#   FORCE=1 bash scripts/90-infra-down.sh  # 確認なし
source "$(dirname "$0")/lib.sh"
need oci jq ssh

stack_id=""
[[ -f "${STATE_DIR}/stack_id" ]] && stack_id="$(cat "${STATE_DIR}/stack_id")"
if [[ -z "${stack_id}" && -n "${OCI_COMPARTMENT_OCID:-}" ]]; then
  stack_id="$(oci resource-manager stack list --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "$(stack_display_name)" --lifecycle-state ACTIVE --query 'data[0].id' --raw-output 2>/dev/null || true)"
fi
[[ -n "${stack_id}" && "${stack_id}" != "null" ]] || die "ORM スタックが見つかりません"

if [[ "${FORCE:-0}" != "1" ]]; then
  printf 'スタック %s の全リソースを削除します。よろしいですか? [y/N] ' "${stack_id}"
  read -r ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || die "中止しました"
fi

# LoadBalancer Service が残っていると VCN のサブネット削除が失敗するため、先に消す（operator 経由・失敗しても続行）
if [[ -f "${SSH_CONFIG}" ]]; then
  info "type=LoadBalancer の Service を削除します（operator 経由）"
  op_ssh -o ConnectTimeout=15 "cd ~/${OPERATOR_REPO_DIR} 2>/dev/null && export KUBECONFIG=\$PWD/kubeconfig && \
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type==\"LoadBalancer\")]}{.metadata.namespace} {.metadata.name}{\"\\n\"}{end}' |
    while read -r ns name; do [ -n \"\$name\" ] && kubectl delete svc -n \"\$ns\" \"\$name\" --wait=true; done" || warn "operator に接続できないためスキップしました"
fi

info "Destroy ジョブを実行します"
job_id="$(oci resource-manager job create-destroy-job --stack-id "${stack_id}" \
  --execution-plan-strategy AUTO_APPROVED --query 'data.id' --raw-output)"
while :; do
  state="$(oci resource-manager job get --job-id "${job_id}" --query 'data."lifecycle-state"' --raw-output)"
  case "${state}" in
    SUCCEEDED) ok "Destroy 完了"; break ;;
    FAILED|CANCELED)
      oci resource-manager job get-job-logs-content --job-id "${job_id}" --query data --raw-output | tail -40 >&2 || true
      die "Destroy ジョブが ${state}（job: ${job_id}）" ;;
    *) log "job state: ${state}"; sleep 30 ;;
  esac
done

info "スタックを削除します"
oci resource-manager stack delete --stack-id "${stack_id}" --force --wait-for-state DELETED >/dev/null
rm -rf "${STATE_DIR}" "${KUBECONFIG}"
ok "OCI 上のデモ環境を削除しました"
