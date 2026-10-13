#!/usr/bin/env bash
# OKE クラスタを OCI Resource Manager (ORM) で作成/更新し、kubeconfig を生成する。
#
#   bash scripts/10-infra-up.sh                    # ORM スタック作成(or 更新) → Apply → kubeconfig
#   bash scripts/10-infra-up.sh --cluster-id <id>  # 既存クラスタ（Deploy to OCI ボタンで作成など）の kubeconfig だけ作る
#
# 必要な環境変数（.env でも可）: OCI_COMPARTMENT_OCID
# 任意: OCI_CLI_PROFILE(DEFAULT) / ADMIN_CIDRS(未設定なら自 IP/32 を自動検出) / CLUSTER_NAME / OKE_CLUSTER_ID
source "$(dirname "$0")/lib.sh"
need oci kubectl jq zip curl

CLUSTER_ID="${OKE_CLUSTER_ID:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    *) die "不明な引数: $1" ;;
  esac
done

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

  local cidrs vars zip stack_id job_id state tenancy region
  tenancy="$(oci_profile_value tenancy)"
  region="$(oci_profile_value region)"
  [[ -n "${tenancy}" && -n "${region}" ]] || die "OCI CLI プロファイル ${OCI_CLI_PROFILE} から tenancy / region を取得できません"
  info "OCI プロファイル: ${OCI_CLI_PROFILE}（region: ${region}）"
  cidrs="$(detect_admin_cidrs)"
  info "Kubernetes API の許可 CIDR: ${cidrs}"
  # ORM コンソールでは tenancy_ocid / region が自動入力されるが、CLI/API では明示的に渡す必要がある
  vars="$(jq -n \
    --arg t "${tenancy}" \
    --arg r "${region}" \
    --arg c "${OCI_COMPARTMENT_OCID}" \
    --arg cidrs "${cidrs}" \
    --arg name "${CLUSTER_NAME:-llm-demo}" \
    --arg kv "${KUBERNETES_VERSION}" \
    '{tenancy_ocid: $t,
      region: $r,
      compartment_ocid: $c,
      admin_cidrs: ($cidrs | split(",") | map(gsub("\\s"; "")) | tojson),
      cluster_name: $name,
      kubernetes_version: $kv}')"
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
    state="$(oci resource-manager job get --job-id "${job_id}" --query 'data."lifecycle-state"' --raw-output)"
    case "${state}" in
      SUCCEEDED) ok "Apply 完了"; break ;;
      FAILED|CANCELED)
        oci resource-manager job get-job-logs-content --job-id "${job_id}" --query data --raw-output | tail -40 >&2 || true
        die "Apply ジョブが ${state} になりました（job: ${job_id}）" ;;
      *) log "job state: ${state}"; sleep 30 ;;
    esac
  done

  CLUSTER_ID="$(oci resource-manager job-output-summary list-job-outputs --job-id "${job_id}" --all \
    --query 'data.items[?"output-name"==`cluster_id`]."output-value" | [0]' --raw-output)"
  [[ -n "${CLUSTER_ID}" && "${CLUSTER_ID}" != "null" ]] || die "cluster_id 出力を取得できません"
}

if [[ -z "${CLUSTER_ID}" ]]; then
  orm_apply
fi
echo "${CLUSTER_ID}" > "${STATE_DIR}/cluster_id"
ok "cluster_id: ${CLUSTER_ID}"

info "kubeconfig を生成します: ${KUBECONFIG}"
rm -f "${KUBECONFIG}"
oci ce cluster create-kubeconfig \
  --cluster-id "${CLUSTER_ID}" \
  --file "${KUBECONFIG}" \
  --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT \
  --profile "${OCI_CLI_PROFILE}" >/dev/null
chmod 600 "${KUBECONFIG}"

EXPECTED_NODES="${WORKER_COUNT:-3}"
ready_nodes() {
  [[ "$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')" -ge "${EXPECTED_NODES}" ]]
}
wait_until 900 "${EXPECTED_NODES} ノード Ready" ready_nodes
kubectl get nodes -o wide
