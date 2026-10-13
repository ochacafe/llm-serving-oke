# fish からでも `make <target>` で実行できる（中身は bash スクリプト）
SHELL := /bin/bash
.DEFAULT_GOAL := help

help: ## このヘルプ
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check: ## 前提ツール / OCI CLI 設定の確認
	bash scripts/00-check-prereqs.sh

up: ## OKE を ORM で作成/更新し kubeconfig を生成（CLUSTER_ID=... で既存クラスタに接続のみ）
	bash scripts/10-infra-up.sh $(if $(CLUSTER_ID),--cluster-id $(CLUSTER_ID),)

platform: ## KServe / agentgateway / 監視を導入（冪等）
	bash scripts/20-platform-install.sh

pf: ## gateway:8080 / grafana:3000 / prometheus:9090 を port-forward
	bash scripts/port-forward.sh start

pf-stop: ## port-forward を停止
	bash scripts/port-forward.sh stop

preflight: ## 本番前の自己診断（Step 1〜3 を自動で通して判定）
	DEMO_AUTO=1 bash scripts/30-preflight.sh

demo-1: ## Step 1: KServe
	bash scripts/demo-step1.sh

demo-2: ## Step 2: 普通の LB vs llm-d
	bash scripts/demo-step2.sh

demo-3: ## Step 3: P/D 分離
	bash scripts/demo-step3.sh

demo-3-logs: ## Step 3 のログ（別ペインで）
	bash scripts/demo-step3.sh logs

demo-diff: ## 締め: YAML 差分
	bash scripts/demo-diff.sh

reset: ## デモ用リソースだけ削除して Step 1 前に戻す
	bash scripts/reset.sh

down: ## ORM Destroy でクラスタ / VCN を削除
	bash scripts/90-infra-down.sh

stack-zip: ## ORM 用 stack.zip を作成
	bash scripts/build-stack-zip.sh

.PHONY: help check up platform pf pf-stop preflight demo-1 demo-2 demo-3 demo-3-logs demo-diff reset down stack-zip
