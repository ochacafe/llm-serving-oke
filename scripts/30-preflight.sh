#!/usr/bin/env bash
# 自己診断。Step 1〜3 を DEMO_AUTO=1 で一通り実行し、受け入れ基準を自動判定する。
#   DEMO_AUTO=1 bash scripts/30-preflight.sh
#   PREFLIGHT_LOAD_DURATION=240（Step 2 の負荷時間 秒）/ PREFLIGHT_KEEP=1（最後に reset しない）
source "$(dirname "$0")/lib.sh"
need kubectl jq curl
require_kubeconfig
cd "${REPO_ROOT}"
export DEMO_AUTO=1

PROM_URL="${PROM_URL:-http://localhost:9090}"
OUT="${REPO_ROOT}/out/preflight-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${OUT}"
RESULTS=()
FAILED=0

check() { # check <id> <説明> <条件コマンド...>
  local id="$1" desc="$2"; shift 2
  if "$@" >>"${OUT}/checks.log" 2>&1; then
    ok "[${id}] ${desc}"; RESULTS+=("OK  [${id}] ${desc}")
  else
    ng "[${id}] ${desc}"; RESULTS+=("NG  [${id}] ${desc}"); FAILED=1
  fi
}

prom() { # prom <PromQL> → 最初の値（なければ空）
  curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result[0].value[1] // empty'
}
prom_nonempty() { [[ "$(curl -sfG "${PROM_URL}/api/v1/query" --data-urlencode "query=$1" | jq '.data.result | length')" -gt 0 ]]; }
fge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && a >= b) }'; }
fle() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a != "" && a <= b) }'; }

# ---------------------------------------------------------------- 0. 基盤
banner "Preflight 0: 基盤の健全性"
nodes_ready() { [[ "$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')" -ge "${WORKER_COUNT:-3}" ]]; }
check 1 "ノード ${WORKER_COUNT:-3} 台 Ready" nodes_ready
check 1 "KServe controller" kubectl rollout status deploy/llmisvc-controller-manager -n kserve --timeout=60s
check 1 "agentgateway controller" kubectl rollout status deploy/agentgateway -n agentgateway-system --timeout=60s
check 1 "Gateway Programmed" kubectl wait --for=condition=Programmed gateway/kserve-ingress-gateway -n kserve --timeout=60s
check 1 "Prometheus / Grafana" kubectl rollout status deploy/kps-grafana -n monitoring --timeout=60s
no_lb() { [[ -z "$(kubectl get svc -A -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}')" ]]; }
check 1 "LoadBalancer Service なし（OCI LB 課金なし）" no_lb

bash "${REPO_ROOT}/scripts/port-forward.sh" start
ensure_loadgen
bash "${REPO_ROOT}/scripts/reset.sh"

# ---------------------------------------------------------------- Step 1
banner "Preflight Step 1"
bash "${REPO_ROOT}/scripts/demo-step1.sh" >"${OUT}/step1.log" 2>&1 || true
step1_curl() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/${DEMO_NS}/sim-baseline/v1/chat/completions" \
    -H 'Content-Type: application/json' -d '{"model":"demo-llm","messages":[{"role":"user","content":"hi"}],"max_tokens":4}')"
  [[ "${code}" == "200" ]]
}
step1_header() {
  curl -s -o /dev/null -D - "${GATEWAY_URL}/${DEMO_NS}/sim-baseline/v1/chat/completions" \
    -H 'Content-Type: application/json' -d '{"model":"demo-llm","messages":[{"role":"user","content":"hi"}],"max_tokens":4}' |
    grep -qi '^x-inference-pod: sim-baseline'
}
step1_tree() {
  local t; t="$(show_tree sim-baseline)"; echo "${t}"
  grep -q 'Deployment/' <<<"${t}" && grep -q 'Service/' <<<"${t}" && grep -q 'HTTPRoute/' <<<"${t}"
}
check 2 "Step 1: Gateway 経由の curl が 200" step1_curl
check 2 "Step 1: x-inference-pod ヘッダーが返る" step1_header
check 2 "Step 1: Deployment / Service / HTTPRoute が生成される" step1_tree

# ---------------------------------------------------------------- Step 2
banner "Preflight Step 2（負荷 ${PREFLIGHT_LOAD_DURATION:-240}s）"
LOADGEN_DURATION="${PREFLIGHT_LOAD_DURATION:-240}" \
LOADGEN_EXTRA="--no-live --summary-json ${LOADGEN_OUT_DIR}/preflight-step2.json" \
  bash "${REPO_ROOT}/scripts/demo-step2.sh" >"${OUT}/step2.log" 2>&1 || true
loadgen_fetch "${LOADGEN_OUT_DIR}/preflight-step2.json" "${OUT}/step2-summary.json" || true

HIT_Q='sum(rate(vllm:prefix_cache_hits_total{llmisvc="%s"}[1m])) / sum(rate(vllm:prefix_cache_queries_total{llmisvc="%s"}[1m]))'
# shellcheck disable=SC2059
hit_base="$(prom "$(printf "${HIT_Q}" sim-baseline sim-baseline)")"
# shellcheck disable=SC2059
hit_llmd="$(prom "$(printf "${HIT_Q}" sim-llmd sim-llmd)")"
p50_base="$(jq -r '.baseline.ttft_p50_ms_last60s // empty' "${OUT}/step2-summary.json" 2>/dev/null || true)"
p50_llmd="$(jq -r '.llmd.ttft_p50_ms_last60s // empty' "${OUT}/step2-summary.json" 2>/dev/null || true)"
conc_base="$(jq -r '.baseline.tenant_concentration_last60s // empty' "${OUT}/step2-summary.json" 2>/dev/null || true)"
conc_llmd="$(jq -r '.llmd.tenant_concentration_last60s // empty' "${OUT}/step2-summary.json" 2>/dev/null || true)"
info "prefix cache hit: baseline=${hit_base:-?} llmd=${hit_llmd:-?} / TTFT p50(ms): baseline=${p50_base:-?} llmd=${p50_llmd:-?} / テナント固定度: baseline=${conc_base:-?} llmd=${conc_llmd:-?}"
{
  echo "hit_base=${hit_base} hit_llmd=${hit_llmd}"
  echo "p50_base=${p50_base} p50_llmd=${p50_llmd}"
  echo "conc_base=${conc_base} conc_llmd=${conc_llmd}"
} >"${OUT}/step2-metrics.txt"
check 3 "Step 2: llm-d の prefix cache ヒット率 ≥ 70%（${hit_llmd:-?}）" fge "${hit_llmd}" 0.7
check 3 "Step 2: ベースラインのヒット率 ≤ 40%（${hit_base:-?}）" fle "${hit_base}" 0.4
ttft_ratio() { awk -v b="${p50_base}" -v l="${p50_llmd}" 'BEGIN { exit !(b != "" && l != "" && l * 3 <= b) }'; }
check 3 "Step 2: llm-d の TTFT p50 がベースラインの 1/3 以下（${p50_llmd:-?} / ${p50_base:-?} ms）" ttft_ratio
conc_gap() { awk -v b="${conc_base}" -v l="${conc_llmd}" 'BEGIN { exit !(b != "" && l != "" && l >= 0.8 && l - b >= 0.3) }'; }
check 3 "Step 2: テナント×Pod で llm-d 側が明確に偏る（${conc_llmd:-?} vs ${conc_base:-?}）" conc_gap

# Grafana: routing ダッシュボードの全パネル（負荷直後に評価）
dash_ok() {
  local f="$1" expr bad=0
  while IFS= read -r expr; do
    if ! prom_nonempty "${expr}"; then echo "no data: ${expr}"; bad=1; fi
  done < <(jq -r '.panels[] | select(.targets) | .targets[].expr' "${f}")
  [[ "${bad}" == 0 ]]
}
check 5 "Grafana routing ダッシュボードの全パネルにデータ" dash_ok "${REPO_ROOT}/platform/grafana/dashboard-routing.json"

# ---------------------------------------------------------------- Step 3
banner "Preflight Step 3"
LOGS="${OUT}/step3-pod-logs.txt"
( follow_logs sim-pd '' >"${LOGS}" 2>&1 ) &
LOG_PID=$!
PD_SINGLE_COUNT=3 bash "${REPO_ROOT}/scripts/demo-step3.sh" >"${OUT}/step3.log" 2>&1 || true

sidecar() {
  kubectl get pods -n "${DEMO_NS}" -l app.kubernetes.io/name=sim-pd,llm-d.ai/role=decode \
    -o jsonpath='{.items[*].spec.initContainers[*].name}' | grep -q llm-d-routing-sidecar
}
check 4 "Step 3: Decode Pod に llm-d-routing-sidecar がある" sidecar

# 追加で数リクエスト送り、Prefill / Decode 両方の Pod にログが出るか
kill "${LOG_PID}" 2>/dev/null || true
( kubectl logs -n "${DEMO_NS}" -l app.kubernetes.io/name=sim-pd --all-containers --prefix -f --tail=0 --max-log-requests=20 >"${LOGS}" 2>&1 ) &
LOG_PID=$!
sleep 5
loadgen single --target "${LOADGEN_GATEWAY_URL}/${DEMO_NS}/sim-pd" --prompt-tokens 3000 --count 3 >"${OUT}/step3-single.txt" 2>&1 || true
sleep 3
kill "${LOG_PID}" 2>/dev/null || true
logs_both() {
  grep -q 'kserve-prefill' "${LOGS}" && grep -Eq 'sim-pd-kserve-[a-z0-9]+-[a-z0-9]+/main' "${LOGS}"
}
check 4 "Step 3: 1 リクエストで Prefill Pod と Decode Pod の両方にログが出る" logs_both
single_ok() { grep -q 'status=200' "${OUT}/step3-single.txt"; }
check 4 "Step 3: Gateway 経由の P/D リクエストが 200" single_ok

count_role() { kubectl get pods -n "${DEMO_NS}" -l "app.kubernetes.io/name=sim-pd,llm-d.ai/role=$1" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' '; }
scale_ok() { [[ "$(count_role prefill)" == 4 && "$(count_role decode)" == 2 ]]; }
check 4 "Step 3: prefill.replicas だけを変えると Prefill Pod だけ増える（prefill=4, decode=2）" wait_until 180 "prefill=4 decode=2" scale_ok

# P/D ダッシュボード用に少し負荷をかけてから判定
loadgen compare --target "pd=${LOADGEN_GATEWAY_URL}/${DEMO_NS}/sim-pd" \
  --tenants 4 --prompt-tokens 3000 --rps 1 --duration 60 --max-tokens 32 --no-live --out-dir "${LOADGEN_OUT_DIR}" >"${OUT}/step3-load.txt" 2>&1 || true
check 5 "Grafana P/D ダッシュボードの全パネルにデータ" dash_ok "${REPO_ROOT}/platform/grafana/dashboard-pd.json"

kubectl patch llmisvc sim-pd -n "${DEMO_NS}" --type merge -p '{"spec":{"prefill":{"replicas":2}}}' >/dev/null

# ---------------------------------------------------------------- reset → Step 1 再実行
banner "Preflight: reset → Step 1 を再実行できるか"
reset_rerun() {
  bash "${REPO_ROOT}/scripts/reset.sh" &&
    kubectl apply -f "${REPO_ROOT}/manifests/step1-baseline.yaml" &&
    wait_llmisvc_ready sim-baseline 300 &&
    step1_curl
}
check 6 "reset 後に Step 1 から再実行できる" reset_rerun

if [[ "${PREFLIGHT_KEEP:-0}" != "1" ]]; then
  bash "${REPO_ROOT}/scripts/reset.sh"
fi

banner "Preflight 結果（詳細: ${OUT}）"
printf '%s\n' "${RESULTS[@]}" | tee "${OUT}/result.txt"
exit "${FAILED}"
