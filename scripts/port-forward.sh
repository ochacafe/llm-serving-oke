#!/usr/bin/env bash
# gateway:8080 / grafana:3000 / prometheus:9090 をまとめて port-forward する（切れても自動で張り直す）。
#   bash scripts/port-forward.sh         # 起動（バックグラウンド）
#   bash scripts/port-forward.sh stop    # 停止
source "$(dirname "$0")/lib.sh"
need kubectl
require_kubeconfig
mkdir -p "${STATE_DIR}"
PIDFILE="${STATE_DIR}/port-forward.pids"

stop() {
  if [[ -f "${PIDFILE}" ]]; then
    while read -r pid; do kill "${pid}" 2>/dev/null || true; done < "${PIDFILE}"
    rm -f "${PIDFILE}"
  fi
  pkill -f "kubectl port-forward.*(kserve-ingress-gateway|kps-grafana|kps-kube-prometheus-stack-prometheus)" 2>/dev/null || true
}

forward() {
  local ns="$1" target="$2" ports="$3"
  (
    while :; do
      kubectl port-forward -n "${ns}" "${target}" "${ports}" --address 127.0.0.1 >/dev/null 2>&1 || true
      sleep 1
    done
  ) </dev/null >/dev/null 2>&1 &
  disown
  echo $! >> "${PIDFILE}"
}

case "${1:-start}" in
  stop) stop; ok "port-forward を停止しました" ;;
  start)
    stop
    forward kserve svc/kserve-ingress-gateway 8080:80
    forward monitoring svc/kps-grafana 3000:80
    forward monitoring svc/kps-kube-prometheus-stack-prometheus 9090:9090
    wait_until 60 "gateway  ${GATEWAY_URL}" curl -s -o /dev/null "${GATEWAY_URL}"
    wait_until 60 "grafana  ${GRAFANA_URL}" curl -sf -o /dev/null "${GRAFANA_URL}/api/health"
    wait_until 60 "prometheus http://localhost:9090" curl -sf -o /dev/null "http://localhost:9090/-/ready"
    ;;
  *) die "usage: $0 [start|stop]" ;;
esac
