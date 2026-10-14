#!/usr/bin/env bash
# 共通関数。各スクリプトの先頭で `source "$(dirname "$0")/lib.sh"` する。
# 接続情報は .env（gitignore 済み）または環境変数から読む。リポジトリには置かない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

# shellcheck source=../versions.env
source "${REPO_ROOT}/versions.env"

# .env は「未設定の変数だけ」補う（明示的に export した環境変数を優先）
if [[ -f "${REPO_ROOT}/.env" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
    key="${key//[[:space:]]/}"
    value="${value%\"}"; value="${value#\"}"
    if [[ -z "${!key:-}" ]]; then
      export "${key}=${value}"
    fi
  done < "${REPO_ROOT}/.env"
fi

export OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"

# operator インスタンス上で動いているか（10-infra-up.sh がリポジトリ同期時に目印を置く）。
# operator 上では OCI CLI をインスタンス・プリンシパルで認証する（鍵をインスタンスに置かない）。
if [[ -f "${HOME}/.llm-demo-operator" ]]; then
  export ON_OPERATOR=1
  export OCI_CLI_AUTH=instance_principal
  unset OCI_CLI_PROFILE
else
  export ON_OPERATOR=0
fi

export KUBECONFIG="${KUBECONFIG_OVERRIDE:-${REPO_ROOT}/kubeconfig}"
export STATE_DIR="${REPO_ROOT}/.state"
export DEMO_NS="llm-demo"
export GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
export GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

# ---- 表示 ----
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

log()  { printf '%s[%s]%s %s\n' "${C_DIM}" "$(date +%H:%M:%S)" "${C_RESET}" "$*" >&2; }
info() { printf '%s==>%s %s%s%s\n' "${C_BLUE}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2; }
warn() { printf '%s[WARN]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
ng()   { printf '%s[ NG ]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
die()  { ng "$*"; exit 1; }

# デモ中の見出し（いま何を見せているか）
banner() {
  local line
  line="$(printf '%*s' 72 '' | tr ' ' '─')"
  printf '\n%s%s%s\n%s%s  %s%s\n%s%s%s\n' "${C_CYAN}" "${line}" "${C_RESET}" \
    "${C_CYAN}" "${C_BOLD}" "$*" "${C_RESET}" "${C_CYAN}" "${line}" "${C_RESET}"
}

# demo-magic 風: コマンドを表示 → Enter で実行。DEMO_AUTO=1 で待たずに実行。
run() {
  local cmd="$*"
  printf '\n%s$%s %s%s%s' "${C_GREEN}" "${C_RESET}" "${C_BOLD}" "${cmd}" "${C_RESET}"
  if [[ "${DEMO_AUTO:-0}" == "1" ]]; then
    printf '\n'
  else
    read -r -s _ </dev/tty || true
    printf '\n'
  fi
  eval "${cmd}"
}

# 次へ進む前の一時停止（説明用）
pause() {
  [[ "${DEMO_AUTO:-0}" == "1" ]] && return 0
  printf '%s%s%s' "${C_DIM}" "${1:-[Enter で次へ]}" "${C_RESET}"
  read -r -s _ </dev/tty || true
  printf '\n'
}

need() {
  local missing=0 c
  for c in "$@"; do
    if ! command -v "${c}" >/dev/null 2>&1; then
      ng "コマンドが見つかりません: ${c}"
      missing=1
    fi
  done
  [[ "${missing}" == 0 ]] || exit 1
}

# 条件が満たされるまで待つ: wait_until <timeout_sec> <説明> <command...>
wait_until() {
  local timeout="$1" desc="$2"; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    if (( SECONDS - start > timeout )); then
      ng "タイムアウト(${timeout}s): ${desc}"
      return 1
    fi
    sleep 5
  done
  ok "${desc}"
}

require_kubeconfig() {
  [[ -f "${KUBECONFIG}" ]] || die "kubeconfig がありません（${KUBECONFIG}）。先に scripts/10-infra-up.sh を実行してください。"
}

# bat / delta があれば使う
show_file() {
  if command -v bat >/dev/null 2>&1; then
    bat --paging=never --style=plain --language=yaml "$1"
  else
    cat "$1"
  fi
}

show_diff() {
  if command -v delta >/dev/null 2>&1; then
    diff -u "$1" "$2" | delta --paging=never || true
  else
    diff -u --color=always "$1" "$2" || true
  fi
}

# ---- loadgen ----
# 既定はクラスタ内 Pod で実行し、表示だけ手元に出す（LOADGEN_MODE=cluster）。
# 手元 → OKE の port-forward は 1 リクエストあたり数百 ms の遅延が乗り、TTFT 比較が成立しないため。
# LOADGEN_MODE=local で手元実行（port-forward 経由）に切り替えられる。
export LOADGEN_MODE="${LOADGEN_MODE:-cluster}"
if [[ "${LOADGEN_MODE}" == "cluster" ]]; then
  export LOADGEN_GATEWAY_URL="${LOADGEN_GATEWAY_URL:-http://kserve-ingress-gateway.kserve.svc.cluster.local}"
  export LOADGEN_OUT_DIR="/tmp/out"
else
  export LOADGEN_GATEWAY_URL="${LOADGEN_GATEWAY_URL:-${GATEWAY_URL}}"
  export LOADGEN_OUT_DIR="${REPO_ROOT}/out"
fi

# loadgen Pod を（ソースが変わっていれば再起動して）用意する
ensure_loadgen() {
  [[ "${LOADGEN_MODE}" == "cluster" ]] || return 0
  local src="${REPO_ROOT}/loadgen" hash
  hash="$(cat "${src}/pyproject.toml" "${src}/uv.lock" "${src}"/src/loadgen/*.py | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-16)"
  kubectl create namespace loadgen --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create configmap loadgen-src -n loadgen \
    --from-file="${src}/pyproject.toml" --from-file="${src}/uv.lock" \
    --from-file="${src}/src/loadgen/__init__.py" --from-file="${src}/src/loadgen/cli.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sed -e "s|__SRC_HASH__|${hash}|" -e "s|__LOADGEN_IMAGE__|${LOADGEN_IMAGE}|" "${src}/k8s.yaml" | kubectl apply -f - >/dev/null
  kubectl rollout status deploy/loadgen -n loadgen --timeout=300s >/dev/null
}

loadgen() {
  if [[ "${LOADGEN_MODE}" == "cluster" ]]; then
    local tty_flag="-i"
    [[ -t 0 && -t 1 ]] && tty_flag="-it"
    kubectl exec "${tty_flag}" -n loadgen deploy/loadgen -- uv run --frozen --no-sync --quiet loadgen "$@"
  else
    uv run --quiet --project "${REPO_ROOT}/loadgen" loadgen "$@"
  fi
}

# loadgen の出力ファイル（CSV / summary JSON）を手元に取り出す: loadgen_fetch <loadgen 側パス> <手元パス>
loadgen_fetch() {
  mkdir -p "$(dirname "$2")"
  if [[ "${LOADGEN_MODE}" == "cluster" ]]; then
    kubectl exec -n loadgen deploy/loadgen -- cat "$1" >"$2"
  else
    cp "$1" "$2"
  fi
}

# OCI CLI プロファイル（~/.oci/config）から値を読む: oci_profile_value <key>
# 環境変数 OCI_CLI_REGION / OCI_CLI_TENANCY があればそちらを優先（OCI CLI と同じ挙動）。
oci_profile_value() {
  local key="$1" cfg="${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}"
  case "${key}" in
    region)  [[ -n "${OCI_CLI_REGION:-}" ]] && { echo "${OCI_CLI_REGION}"; return; } ;;
    tenancy) [[ -n "${OCI_CLI_TENANCY:-}" ]] && { echo "${OCI_CLI_TENANCY}"; return; } ;;
  esac
  awk -v prof="[${OCI_CLI_PROFILE}]" -v key="${key}" '
    $0 == prof { in_prof = 1; next }
    /^\[/ { in_prof = 0 }
    in_prof {
      line = $0; sub(/^[ \t]+/, "", line)
      split(line, kv, "=")
      k = kv[1]; gsub(/[ \t]+$/, "", k)
      if (k == key) { v = substr(line, index(line, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
    }' "${cfg}"
}

# ---- 踏み台（bastion）→ operator ----
# Kubernetes API はプライベートなので、kubectl / helm は operator 上で実行する。
# 手元で実行したスクリプトは delegate_to_operator で operator に委譲される。
export SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/llm-serving-oke}"
export SSH_CONFIG="${STATE_DIR}/ssh_config"
export OPERATOR_REPO_DIR="llm-serving-oke"

# このデモ専用の SSH 鍵（無ければ作る）。公開鍵は ORM のスタック変数としてのみ渡す
ensure_ssh_key() {
  if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    info "SSH 鍵を作成します: ${SSH_KEY_PATH}"
    ssh-keygen -q -t ed25519 -N "" -C "llm-serving-oke" -f "${SSH_KEY_PATH}"
  fi
}

write_ssh_config() { # write_ssh_config <bastion_public_ip> <operator_private_ip>
  mkdir -p "${STATE_DIR}"
  cat >"${SSH_CONFIG}" <<CFG
Host llm-demo-bastion
  HostName $1
  User opc
  IdentityFile ${SSH_KEY_PATH}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${STATE_DIR}/known_hosts
  ServerAliveInterval 30

Host llm-demo-operator
  HostName $2
  User opc
  ProxyJump llm-demo-bastion
  IdentityFile ${SSH_KEY_PATH}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${STATE_DIR}/known_hosts
  ServerAliveInterval 30
CFG
}

op_ssh() {
  [[ -f "${SSH_CONFIG}" ]] || die "SSH 設定がありません（${SSH_CONFIG}）。先に make up を実行してください。"
  ssh -F "${SSH_CONFIG}" llm-demo-operator "$@"
}

# デモに必要なファイルだけ operator に同期する（.env / kubeconfig / .state などは送らない）
sync_repo() {
  ( cd "${REPO_ROOT}" &&
    COPYFILE_DISABLE=1 tar czf - --exclude 'loadgen/.venv' --exclude '__pycache__' \
      Makefile versions.env scripts manifests platform loadgen ) |
    op_ssh "mkdir -p ~/${OPERATOR_REPO_DIR} && tar xzf - -C ~/${OPERATOR_REPO_DIR} 2>/dev/null && touch ~/.llm-demo-operator"
}

# 手元で呼ばれたら operator に同期して同じスクリプトを実行し、終了する
#   delegate_to_operator "$0" "$@"
delegate_to_operator() {
  [[ "${ON_OPERATOR}" == "1" ]] && return 0
  local script rel tty_flag="" env_args=""
  script="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
  rel="${script#"${REPO_ROOT}"/}"
  sync_repo
  [[ -t 0 && -t 1 ]] && tty_flag="-t"
  local v
  for v in DEMO_AUTO LOADGEN_MODE LOADGEN_DURATION LOADGEN_RPS LOADGEN_TENANTS LOADGEN_PROMPT_TOKENS LOADGEN_EXTRA \
           PD_SINGLE_COUNT PREFLIGHT_LOAD_DURATION PREFLIGHT_KEEP WORKER_COUNT FORCE; do
    [[ -n "${!v:-}" ]] && env_args+=" ${v}=$(printf '%q' "${!v}")"
  done
  # shellcheck disable=SC2029
  exec ssh -F "${SSH_CONFIG}" ${tty_flag} llm-demo-operator \
    "cd ~/${OPERATOR_REPO_DIR} && env${env_args} bash ${rel} $(printf '%q ' "$@")"
}

stack_display_name() {
  echo "llm-serving-oke-${CLUSTER_NAME:-llm-demo}"
}

# LLMInferenceService から生成されたリソースを表示（kubectl tree があれば使う）
show_tree() {
  local name="$1"
  if kubectl tree --help >/dev/null 2>&1; then
    kubectl tree llminferenceservice "${name}" -n "${DEMO_NS}"
    return
  fi
  # フォールバック: ownerReferences を辿って一覧表示
  local uid
  uid="$(kubectl get llminferenceservice "${name}" -n "${DEMO_NS}" -o jsonpath='{.metadata.uid}')"
  printf '%sLLMInferenceService/%s%s\n' "${C_BOLD}" "${name}" "${C_RESET}"
  kubectl get deployments,replicasets,services,httproutes.gateway.networking.k8s.io,inferencepools.inference.networking.k8s.io,serviceaccounts,roles,rolebindings,secrets,configmaps,pods \
    -n "${DEMO_NS}" -o json 2>/dev/null |
    jq -r --arg uid "${uid}" '
      .items as $all
      | def children($u): [$all[] | select(any(.metadata.ownerReferences[]?; .uid == $u))];
        def walk($u; $depth):
          children($u)[] | ("\("  " * $depth)└─ \(.kind)/\(.metadata.name)"), walk(.metadata.uid; $depth + 1);
        walk($uid; 1)'
}

# ログ追従（stern があれば使う）
follow_logs() {
  local selector_name="$1" include="${2:-}"
  if command -v stern >/dev/null 2>&1; then
    stern -n "${DEMO_NS}" -l "app.kubernetes.io/name=${selector_name}" --all-namespaces=false \
      ${include:+--include "${include}"} --tail 0
  else
    kubectl logs -n "${DEMO_NS}" -l "app.kubernetes.io/name=${selector_name}" --all-containers --prefix -f --tail=0 --max-log-requests=20 |
      { if [[ -n "${include}" ]]; then grep --line-buffered -E "${include}"; else cat; fi; }
  fi
}

wait_llmisvc_ready() {
  local name="$1" timeout="${2:-300}"
  kubectl wait --for=condition=Ready "llminferenceservice/${name}" -n "${DEMO_NS}" --timeout="${timeout}s"
}

open_url() {
  if [[ "${DEMO_AUTO:-0}" == "1" ]]; then
    log "open ${1}"
  elif command -v open >/dev/null 2>&1; then
    open "$1"
  else
    log "ブラウザで開いてください: $1"
  fi
}
