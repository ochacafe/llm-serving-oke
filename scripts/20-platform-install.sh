#!/usr/bin/env bash
# プラットフォーム導入（冪等。何度実行してもよい）
#   Gateway API CRD → cert-manager → KServe(LLMISVC) → GIE CRD → agentgateway → Gateway → 監視
# 順序が重要（GIE CRD は KServe チャートの後、agentgateway は GIE CRD の後）。
# OKE (K8s >= 1.34) の CRI-O は short name のイメージ（kserve/xxx）を拒否するため、docker.io/ を明示する。
source "$(dirname "$0")/lib.sh"
delegate_to_operator "$0" "$@"
need kubectl helm openssl
require_kubeconfig

# Helm 4 は server-side apply。KServe コントローラーが正規化したフィールドと衝突するため再実行時は強制する
HELM_FLAGS=()
if [[ "$(helm version --template '{{.Version}}')" == v4* ]]; then
  HELM_FLAGS+=(--force-conflicts)
fi

# --- 1. Gateway API CRD ---
info "1/7 Gateway API CRD ${GATEWAY_API_VERSION}"
kubectl apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null

# --- 2. cert-manager（KServe の webhook 証明書用） ---
info "2/7 cert-manager ${CERT_MANAGER_VERSION}"
kubectl apply --server-side --force-conflicts -f \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
kubectl wait --for=condition=available deployment --all -n cert-manager --timeout=300s

# --- 3. KServe（LLMInferenceService のみ） ---
info "3/7 KServe LLMISVC ${KSERVE_VERSION}"
kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f - >/dev/null

helm upgrade -i ${HELM_FLAGS[@]+"${HELM_FLAGS[@]}"} kserve-llmisvc-crd oci://ghcr.io/kserve/charts/kserve-llmisvc-crd \
  --version "${KSERVE_VERSION}" -n kserve --wait

helm upgrade -i ${HELM_FLAGS[@]+"${HELM_FLAGS[@]}"} kserve-llmisvc-resources oci://ghcr.io/kserve/charts/kserve-llmisvc-resources \
  --version "${KSERVE_VERSION}" -n kserve \
  --set kserve.llmisvc.controller.image=docker.io/kserve/llmisvc-controller \
  --set kserve.storage.image=docker.io/kserve/storage-initializer \
  --set kserve.agent.image=docker.io/kserve/agent \
  --set kserve.router.image=docker.io/kserve/router \
  --set kserve.controller.deploymentMode=Standard \
  --set kserve.controller.gateway.ingressGateway.enableGatewayApi=true \
  --set kserve.controller.gateway.ingressGateway.createGateway=false \
  --set kserve.controller.gateway.ingressGateway.kserveGateway=kserve/kserve-ingress-gateway \
  --set kserve.controller.gateway.ingressGateway.className=agentgateway \
  --set kserve.controller.gateway.disableIstioVirtualHost=true \
  --set kserve.controller.gateway.disableIngressCreation=false \
  --set kserve.controller.knativeAddressableResolver.enabled=false \
  --set kserve.controller.gateway.localGateway.gateway="" \
  --set kserve.controller.gateway.localGateway.gatewayService=""

kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=300s

helm upgrade -i ${HELM_FLAGS[@]+"${HELM_FLAGS[@]}"} kserve-runtime-configs oci://ghcr.io/kserve/charts/kserve-runtime-configs \
  --version "${KSERVE_VERSION}" -n kserve \
  --set kserve.llmisvcConfigs.enabled=true

# --- 4. GIE CRD（KServe チャートの後に適用する） ---
info "4/7 Gateway API Inference Extension CRD ${GIE_VERSION}"
kubectl apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml" >/dev/null

# --- 5. agentgateway（GIE CRD の後。InferencePool を検出させるため） ---
info "5/7 agentgateway ${AGENTGATEWAY_VERSION}"
helm upgrade -i ${HELM_FLAGS[@]+"${HELM_FLAGS[@]}"} agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace -n agentgateway-system --version "${AGENTGATEWAY_VERSION}"
helm upgrade -i ${HELM_FLAGS[@]+"${HELM_FLAGS[@]}"} agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  -n agentgateway-system --version "${AGENTGATEWAY_VERSION}" \
  --set inferenceExtension.enabled=true --wait

# --- 6. 共有 Gateway（Service は ClusterIP。OCI LB は作らない） ---
info "6/7 Gateway kserve/kserve-ingress-gateway"
kubectl apply -f "${REPO_ROOT}/platform/gateway.yaml"
kubectl wait --for=condition=Programmed gateway/kserve-ingress-gateway -n kserve --timeout=300s

# --- 7. 監視 ---
info "7/7 kube-prometheus-stack ${KPS_VERSION}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Grafana 管理者パスワードはクラスタ内でランダム生成（既存なら維持）。リポジトリ・ローカルファイルには残さない。
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)" >/dev/null
  ok "Grafana 管理者パスワードを生成しました（kubectl get secret grafana-admin -n monitoring で確認）"
fi
kubectl create configmap grafana-dashboards-llm-demo -n monitoring \
  --from-file="${REPO_ROOT}/platform/grafana/dashboard-routing.json" \
  --from-file="${REPO_ROOT}/platform/grafana/dashboard-pd.json" \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f - >/dev/null

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade -i ${HELM_FLAGS[@]+"${HELM_FLAGS[@]}"} kps prometheus-community/kube-prometheus-stack \
  -n monitoring --version "${KPS_VERSION}" \
  -f "${REPO_ROOT}/platform/kube-prometheus-values.yaml" --wait --timeout 10m

# --- デモ namespace / loadgen Pod ---
kubectl apply -f "${REPO_ROOT}/manifests/00-namespace.yaml" >/dev/null
info "loadgen Pod（クラスタ内から負荷をかける）"
ensure_loadgen

# --- LoadBalancer が作られていないことを確認（§11-8） ---
lbs="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
if [[ -n "${lbs}" ]]; then
  warn "type=LoadBalancer の Service があります（OCI LB が課金されます）:"
  echo "${lbs}" >&2
else
  ok "LoadBalancer Service なし（アクセスは port-forward）"
fi

ok "プラットフォーム導入完了。次: bash scripts/port-forward.sh"
