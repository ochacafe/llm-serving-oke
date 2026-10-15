#!/usr/bin/env bash
# OKE クラスタと踏み台（bastion / operator）を OCI Resource Manager (ORM) で作成/更新し、
# operator 上で kubeconfig を生成する。
#
#   bash scripts/10-infra-up.sh   # ORM スタック作成(or 更新) → Apply → SSH 設定 → operator 初期化
#
# 必要な環境変数（.env でも可）: OCI_COMPARTMENT_OCID
# 任意: OCI_CLI_PROFILE(DEFAULT) / ADMIN_CIDRS(未設定なら自 IP/32 を自動検出) / CLUSTER_NAME / SSH_KEY_PATH
source "$(dirname "$0")/lib.sh"
need oci jq zip curl ssh ssh-keygen tar

mkdir -p "${STATE_DIR}"

detect_admin_cidrs() {
  if [[ -n "${ADMIN_CIDRS:-}" ]]; then
    echo "${ADMIN_CIDRS}"
    return
  fi
  local ip
  ip="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')" || die "グローバル IP を検出できません。ADMIN_CIDRS を指定してください。"
  echo "${ip}/32"
}

find_stack_id() {
  if [[ -f "${STATE_DIR}/stack_id" ]]; then
    cat "${STATE_DIR}/stack_id"
    return
  fi
  oci resource-manager stack list --compartment-id "${OCI_COMPARTMENT_OCID}" \
    --display-name "$(stack_display_name)" --lifecycle-state ACTIVE \
    --query 'data[0].id' --raw-output 2>/dev/null || true
}

orm_apply() {
  [[ -n "${OCI_COMPARTMENT_OCID:-}" ]] || die "OCI_COMPARTMENT_OCID が未設定です（.env.example 参照）"

  local cidrs vars zip stack_id job_id state tenancy region pubkey
  tenancy="$(oci_profile_value tenancy)"
  region="$(oci_profile_value region)"
  [[ -n "${tenancy}" && -n "${region}" ]] || die "OCI CLI プロファイル ${OCI_CLI_PROFILE} から tenancy / region を取得できません"
  info "OCI プロファイル: ${OCI_CLI_PROFILE}（region: ${region}）"
  cidrs="$(detect_admin_cidrs)"
  info "踏み台への SSH を許可する CIDR: ${cidrs}"
  ensure_ssh_key
  pubkey="$(cat "${SSH_KEY_PATH}.pub")"
  # ORM の CLI/API では tenancy_ocid / region を明示的に渡す必要がある
  vars="$(jq -n \
    --arg t "${tenancy}" \
    --arg r "${region}" \
    --arg c "${OCI_COMPARTMENT_OCID}" \
    --arg cidrs "${cidrs}" \
    --arg name "${CLUSTER_NAME:-llm-demo}" \
    --arg kv "${KUBERNETES_VERSION}" \
    --arg key "${pubkey}" \
    '{tenancy_ocid: $t,
      region: $r,
      compartment_ocid: $c,
      admin_cidrs: ($cidrs | split(",") | map(gsub("\\s"; "")) | tojson),
      cluster_name: $name,
      kubernetes_version: $kv,
      ssh_public_key: $key}')"
  echo "${vars}" > "${STATE_DIR}/stack-variables.json"

  zip="$(bash "${REPO_ROOT}/scripts/build-stack-zip.sh" "${STATE_DIR}/stack.zip")"
  stack_id="$(find_stack_id)"

  if [[ -z "${stack_id}" || "${stack_id}" == "null" ]]; then
    info "ORM スタックを作成します: $(stack_display_name)"
    stack_id="$(oci resource-manager stack create \
      --compartment-id "${OCI_COMPARTMENT_OCID}" \
      --display-name "$(stack_display_name)" \
      --description "vLLM / llm-d / KServe demo (llm-serving-oke)" \
      --config-source "${zip}" \
      --terraform-version "${TF_VERSION_ORM}" \
      --variables "file://${STATE_DIR}/stack-variables.json" \
      --freeform-tags '{"project":"llm-serving-oke"}' \
      --query 'data.id' --raw-output)"
  else
    info "既存の ORM スタックを更新します: ${stack_id}"
    oci resource-manager stack update --stack-id "${stack_id}" \
      --config-source "${zip}" \
      --terraform-version "${TF_VERSION_ORM}" \
      --variables "file://${STATE_DIR}/stack-variables.json" \
      --force >/dev/null
  fi
  echo "${stack_id}" > "${STATE_DIR}/stack_id"

  info "Apply ジョブを実行します（初回は 15〜20 分程度）"
  job_id="$(oci resource-manager job create-apply-job --stack-id "${stack_id}" \
    --execution-plan-strategy AUTO_APPROVED \
    --display-name "apply-$(date +%Y%m%d-%H%M%S)" \
    --query 'data.id' --raw-output)"
  echo "${job_id}" > "${STATE_DIR}/last_job_id"
  log "job: ${job_id}"

  while :; do
    # API が一時的にタイムアウトしてもジョブは OCI 側で進むので、取得失敗は再試行する
    state="$(oci resource-manager job get --job-id "${job_id}" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)" || state="UNKNOWN(取得失敗・再試行)"
    case "${state}" in
      SUCCEEDED) ok "Apply 完了"; break ;;
      FAILED|CANCELED)
        oci resource-manager job get-job-logs-content --job-id "${job_id}" --query data --raw-output | tail -40 >&2 || true
        die "Apply ジョブが ${state} になりました（job: ${job_id}）" ;;
      *) log "job state: ${state}"; sleep 30 ;;
    esac
  done

  oci resource-manager job-output-summary list-job-outputs --job-id "${job_id}" --all \
    --query 'data.items[].{k:"output-name",v:"output-value"}' >"${STATE_DIR}/outputs.json"
}

output_value() {
  jq -r --arg k "$1" '.[] | select(.k == $k) | .v' "${STATE_DIR}/outputs.json"
}

orm_apply
CLUSTER_ID="$(output_value cluster_id)"
BASTION_IP="$(output_value bastion_public_ip)"
OPERATOR_IP="$(output_value operator_private_ip)"
[[ -n "${CLUSTER_ID}" && -n "${BASTION_IP}" && -n "${OPERATOR_IP}" ]] || die "ORM の出力（cluster_id / bastion_public_ip / operator_private_ip）を取得できません"
echo "${CLUSTER_ID}" > "${STATE_DIR}/cluster_id"
ok "cluster_id: ${CLUSTER_ID}"

info "SSH 設定を書き出します: ${SSH_CONFIG}（bastion ${BASTION_IP} → operator ${OPERATOR_IP}）"
write_ssh_config "${BASTION_IP}" "${OPERATOR_IP}"
op_reachable() { op_ssh -o ConnectTimeout=10 -o BatchMode=yes true; }
wait_until 600 "operator に SSH 接続できる" op_reachable
info "operator の初期化（cloud-init: kubectl / helm / OCI CLI の導入）を待ちます"
op_ssh "sudo cloud-init status --wait >/dev/null; sudo cloud-init status"

info "operator にリポジトリを同期し、kubeconfig を生成します"
sync_repo
op_ssh "cd ~/${OPERATOR_REPO_DIR} && WORKER_COUNT=${WORKER_COUNT:-3} bash scripts/operator-init.sh ${CLUSTER_ID}"

ok "完了。次: make platform（operator 上で実行されます）。operator に入る場合: make ssh"
