#!/usr/bin/env bash
# gateway:8080 / grafana:3000 / prometheus:9090 をまとめて port-forward する（切れても自動で張り直す）。
#   bash scripts/port-forward.sh         # 起動（バックグラウンド）
#   bash scripts/port-forward.sh stop    # 停止
#
# 手元で実行した場合: operator 上で kubectl port-forward を常駐させ、手元 → operator を SSH トンネルでつなぐ。
#   手元のブラウザで http://localhost:3000 （Grafana）が開ける。
# operator 上で実行した場合: kubectl port-forward だけを行う。
source "$(dirname "$0")/lib.sh"
mkdir -p "${STATE_DIR}"
ACTION="${1:-start}"
PORTS=(8080 3000 9090)

# ---- 手元: operator 側を起動/停止し、SSH トンネルを張る ----
if [[ "${ON_OPERATOR}" != "1" ]]; then
  TUNNEL_PID="${STATE_DIR}/tunnel.pid"
  stop_tunnel() {
    if [[ -f "${TUNNEL_PID}" ]]; then
      kill "$(cat "${TUNNEL_PID}")" 2>/dev/null || true
      rm -f "${TUNNEL_PID}"
    fi
  }
  sync_repo
  case "${ACTION}" in
    stop)
      stop_tunnel
      op_ssh "cd ~/${OPERATOR_REPO_DIR} && bash scripts/port-forward.sh stop" || true
      ok "SSH トンネルと port-forward を停止しました"
      ;;
    start)
      op_ssh "cd ~/${OPERATOR_REPO_DIR} && bash scripts/port-forward.sh start"
      stop_tunnel
      forwards=()
      for p in "${PORTS[@]}"; do forwards+=(-L "127.0.0.1:${p}:127.0.0.1:${p}"); done
      ssh -F "${SSH_CONFIG}" -f -N -o ExitOnForwardFailure=yes "${forwards[@]}" llm-demo-operator \
        </dev/null >/dev/null 2>&1
      pgrep -f "ssh -F ${SSH_CONFIG} -f -N" | head -1 >"${TUNNEL_PID}"
      wait_until 30 "手元 → gateway  ${GATEWAY_URL}" curl -s -o /dev/null "${GATEWAY_URL}"
      wait_until 30 "手元 → grafana  ${GRAFANA_URL}" curl -sf -o /dev/null "${GRAFANA_URL}/api/health"
      ;;
    *) die "usage: $0 [start|stop]" ;;
  esac
  exit 0
fi

# ---- operator: kubectl port-forward を常駐させる ----
need kubectl
require_kubeconfig
PIDFILE="${STATE_DIR}/port-forward.pids"

stop() {
  if [[ -f "${PIDFILE}" ]]; then
    while read -r pid; do kill -- "-${pid}" 2>/dev/null || kill "${pid}" 2>/dev/null || true; done < "${PIDFILE}"
    rm -f "${PIDFILE}"
  fi
  pkill -f "kubectl port-forward.*(kserve-ingress-gateway|kps-grafana|kps-kube-prometheus-stack-prometheus)" 2>/dev/null || true
}

forward() {
  local ns="$1" target="$2" ports="$3"
  # setsid で SSH セッションから切り離す（ログアウトしても止まらない）
  setsid bash -c "while :; do kubectl port-forward -n ${ns} ${target} ${ports} --address 127.0.0.1 >/dev/null 2>&1 || true; sleep 1; done" \
    </dev/null >/dev/null 2>&1 &
  echo $! >> "${PIDFILE}"
}

case "${ACTION}" in
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
