# llm-serving-oke — vLLM / llm-d / KServe 入門デモ（OKE, GPU なし）

1 つの `LLMInferenceService` の YAML を少しずつ書き足して、
**KServe → llm-d スケジューラ → Prefill/Decode 分離** へと進化させる 15〜20 分のデモです。
推論エンジンは GPU 不要の vLLM 互換シミュレーター [llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim) を使い、
OCI Container Engine for Kubernetes (OKE) の CPU ノードだけで動きます。

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/ochacafe/llm-serving-oke/releases/latest/download/stack.zip)

| Step | 見せること | 書き足す YAML |
|---|---|---|
| 1 | YAML 1 枚から Deployment / Service / HTTPRoute が自動生成される | — |
| 2 | 普通の L7 LB（P2C）と llm-d スケジューラ（prefix cache 考慮）を同じ負荷で比較 | `router.scheduler` |
| 3 | Prefill Pod → Decode Pod のリレーと、Prefill だけの独立スケール | `prefill:`（EPP 設定は KServe 既定の P/D 用に任せる） |
| 締め | `diff` で Step 1 → 2 → 3 の差分 | — |

```
手元の端末 ──port-forward 8080──▶ agentgateway (Gateway: kserve-ingress-gateway)
                                     ├─ HTTPRoute ─▶ Service ─▶ sim-baseline ×4      (P2C)
                                     ├─ HTTPRoute ─▶ InferencePool ─▶ EPP ─▶ sim-llmd ×4
                                     └─ HTTPRoute ─▶ InferencePool ─▶ EPP ─▶ sim-pd (prefill ×2 / decode ×2 + routing sidecar)
            ──port-forward 3000──▶ Grafana ◀── Prometheus（Pod アノテーションで 5 秒間隔 scrape）
```

---

## 構成

| パス | 内容 |
|---|---|
| `terraform/` | OKE（Basic / flannel / E5.Flex ×3）を作る **OCI Resource Manager スタック**（`schema.yaml` 付き） |
| `platform/` | Gateway、kube-prometheus-stack の values、Grafana ダッシュボード 2 枚 |
| `manifests/` | Step 1〜3 の `LLMInferenceService` |
| `loadgen/` | デモ専用の負荷生成ツール（Python / uv）。`k8s.yaml` はクラスタ内実行用 Pod |
| `scripts/` | 構築・デモ・診断・削除スクリプト（bash。fish からも `bash scripts/xxx.sh` / `make xxx` で実行可） |
| `versions.env` | バージョン固定表 |

## 接続情報・シークレットの扱い

このリポジトリには **OCID・IP アドレス・鍵・kubeconfig・パスワードを一切置きません**。

| 情報 | 置き場所 |
|---|---|
| OCI 認証・リージョン | 各自の `~/.oci/config`（`OCI_CLI_PROFILE`、既定 `DEFAULT`） |
| コンパートメント OCID / 許可 CIDR | 環境変数 or `.env`（`.gitignore` 済み。雛形は `.env.example`） |
| Terraform state | OCI Resource Manager が管理（手元に tfstate を作らない） |
| ORM スタック ID 等 | `.state/`（`.gitignore` 済み） |
| kubeconfig | `./kubeconfig`（`.gitignore` 済み。トークンは OCI CLI が都度発行） |
| Grafana 管理者パスワード | クラスタ内でランダム生成した Secret のみ（匿名閲覧 ON なので通常は不要） |

Kubernetes API エンドポイントは利用者の IP（`admin_cidrs`）だけに開放し、Gateway / Grafana は LoadBalancer を作らず port-forward でのみアクセスします。
CI（`.github/workflows/ci.yml`）で gitleaks と OCID 混入チェックを実行します。

---

## 前提

- OCI テナンシ（`VM.Standard.E5.Flex` を 6 OCPU 使えること）と、OKE / VCN を作成できるコンパートメント
- 手元: `oci`（設定済みプロファイル）, `kubectl`, `helm`, `jq`, `curl`, `zip`, `openssl`, [`uv`](https://docs.astral.sh/uv/)
- 任意: `stern`, `bat`, `delta`, `kubectl tree`（krew）。無ければフォールバック表示

```bash
cp .env.example .env   # OCI_COMPARTMENT_OCID を設定
make check             # = bash scripts/00-check-prereqs.sh
```

## 1. OKE を作る（OCI Resource Manager）

### A. スクリプトから（推奨）

```bash
make up                # = bash scripts/10-infra-up.sh
```

1. 手元のグローバル IP を検出して `admin_cidrs` にする（`ADMIN_CIDRS=1.2.3.4/32,...` で上書き可）
2. `terraform/` から `stack.zip` を作り、ORM スタックを作成（2 回目以降は更新）
3. ORM の Apply ジョブを実行（初回 15〜20 分）
4. 出力の `cluster_id` から `./kubeconfig` を生成し、ノード Ready を待つ

リージョンは OCI CLI プロファイルのものを使います（コードにリージョン名は持たせていません）。
**手元のグローバル IP が変わったら `make up` を再実行**すれば許可 CIDR だけ更新されます。

### B. Deploy to OCI ボタンから

1. 上の **Deploy to Oracle Cloud** ボタン → OCI コンソールでリージョンを選ぶ（例: US Midwest (Chicago)）
2. コンパートメントと「Kubernetes API の許可 CIDR」（自分のグローバル IP/32）を入力して作成 → **Apply**
3. 完了後、Outputs の `cluster_id` で kubeconfig を作成

```bash
bash scripts/10-infra-up.sh --cluster-id <cluster_id>
```

> ボタンは GitHub Release の `stack.zip` を参照します。`v*` タグを push すると
> `.github/workflows/release-stack.yml` が `terraform/` から `stack.zip` を作って Release に添付します。

## 2. プラットフォームを入れる

```bash
make platform   # = bash scripts/20-platform-install.sh（冪等）
make pf         # = bash scripts/port-forward.sh（gateway:8080 / grafana:3000 / prometheus:9090）
```

Gateway API CRD → cert-manager → KServe(LLMInferenceService) → GIE CRD → agentgateway → Gateway → kube-prometheus-stack の順に入れます（順序が重要）。

## 3. デモ

```bash
make preflight   # Step 1〜3 を自動で通して受け入れ基準を判定（約 10 分）
make demo-1      # Step 1
make demo-2      # Step 2（Grafana: http://localhost:3000/d/routing）
make demo-3      # Step 3（別ペインで make demo-3-logs、Grafana: http://localhost:3000/d/pd）
make demo-diff   # 締め
make reset       # デモ用リソースを消して Step 1 前に戻す
```

各スクリプトは「コマンドを表示 → Enter で実行」形式です。`DEMO_AUTO=1` で Enter 待ちをスキップします。

### loadgen はクラスタ内で動かす

`loadgen` は既定で **クラスタ内の Pod（namespace `loadgen`）で実行し、`kubectl exec -it` で画面だけ手元に出します**。
手元（日本）→ OKE（シカゴ）の `kubectl port-forward` を経由すると 1 リクエストあたり約 0.5 秒が TTFT に上乗せされ、
llm-d の効果（数十 ms）が埋もれてしまうためです（実測: port-forward 経由 TTFB 0.5〜1.3 秒 / クラスタ内 35 ms）。
ソースは ConfigMap で Pod に渡すのでイメージのビルドは不要です。手元で実行したい場合は `LOADGEN_MODE=local` を付けます。

```bash
# 単体で使う場合（Step 2 と同じ比較を 5 分）
bash -c 'source scripts/lib.sh; ensure_loadgen; loadgen compare \
  --target baseline=$LOADGEN_GATEWAY_URL/llm-demo/sim-baseline \
  --target llmd=$LOADGEN_GATEWAY_URL/llm-demo/sim-llmd --tenants 10 --rps 4 --duration 300'
```

## 4. 片付け

```bash
make down        # = bash scripts/90-infra-down.sh（ORM Destroy → スタック削除）
```

Deploy ボタンで作った場合は、OCI コンソールの Resource Manager からスタックを **Destroy** → 削除してください。

---

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `kubectl` がタイムアウト | IP が変わった可能性。`make up` で許可 CIDR を更新 |
| port-forward が切れる | `make pf` を再実行（スクリプトは切断時に自動で張り直す） |
| LLMInferenceService が Ready にならない | `kubectl describe llmisvc -n llm-demo <name>` / `kubectl logs -n kserve deploy/llmisvc-controller-manager` |
| Step 2 で差が出ない | 負荷開始から 1 分待つ。`make reset` で KV キャッシュを空にしてやり直す |

---

## 調整済みパラメータと実測値

シミュレーターと負荷のパラメータは、初期設計値から受け入れ基準を満たすよう次のとおり調整しました（2026-10-12、us-chicago-1 / E5.Flex 2 OCPU ×3）。

| 項目 | 初期値 | 調整後 | 理由 |
|---|---|---|---|
| sim `--max-num-seqs` | 8 | **3** | 同時実行 × 約 250 ブロックが KV 容量を超えると sim が `500: kv cache does not have sufficient capacity` を返すため |
| sim `--kv-cache-size` | 600 | **800** | 3 並列（約 750 ブロック）を収めつつ、1 Pod あたり約 3 テナント分しか保持できない大きさ |
| テナント数 | 8 | **10** | ベースラインのヒット率を 40% 以下に下げるため（容量 3 テナント / 10 テナント） |
| EPP スコアラー重み（prefix / queue / kv-util） | 3 / 2 / 2 | **5 / 1 / 1** | 3 / 2 / 2 では負荷時にテナントが 2 Pod に割れ、固定度 67% に留まったため |
| loadgen の実行場所 | 手元（port-forward） | **クラスタ内 Pod** | 上記「loadgen はクラスタ内で動かす」参照 |

`30-preflight.sh` の実測（負荷 4 rps/ターゲット、プロンプト約 4,000 トークン、max_tokens 64、開始 4 分後の直近 1 分）:

| 指標 | 普通の LB（P2C） | llm-d スケジューラ | 基準 |
|---|---|---|---|
| Prefix cache ヒット率 | 30% | 89% | llm-d ≥ 70% / ベースライン ≤ 40% |
| TTFT p50 | 1,252 ms | 47 ms | llm-d ≤ ベースラインの 1/3 |
| テナント固定度（各テナントが最も多く当たった Pod の割合の平均） | 36% | 100% | llm-d 側が明確に偏る |
| エラー | 0 | 0 | — |

Step 3（P/D）: Prefill Pod（`--time-to-first-token 1500ms`）→ Decode Pod（KV 転送 100 ms）の順にログが出て、TTFT は約 1.6 秒。
`prefill.replicas: 4` へのパッチで Prefill Pod だけ 2 → 4 台になり、Decode Pod は再作成されないことを確認しています。

## 検証メモ

2026-10-12 に OKE v1.35.2（us-chicago-1）で検証した結果です。

| # | 項目 | 結果 |
|---|---|---|
| 1 | KServe v0.20.0 で agentgateway 手順が動くか | **動作**（rc0 へのフォールバック不要）。ただし後述の short name 問題でイメージ名に `docker.io/` の明示が必要 |
| 2 | `GlobalConfig.EnableTLS` | **無効**。sim の TLS 引数は空文字になり、scrape は http のまま |
| 3 | sim v0.11.2 の `--latency-calculator per-token` / `--enable-kvcache`（ZMQ 未指定） | **動作**。ZMQ の接続先が無くても起動・KV キャッシュ計算・メトリクス出力に影響なし |
| 4 | EPP `prefix-cache-scorer` のデフォルト設定 | パラメータ指定なしで狙いどおり固定される。重みのみ 5/1/1 に調整 |
| 5 | P/D 時の EPP 設定 | `config` 未指定なら KServe が `disagg-profile-handler` + `always-disagg-pd-decider`（閾値 0 = 全リクエストを P/D）を自動生成。**Step 2 の inline config を残すと P/D 用プロファイルにならないため、Step 3 では `config` を書かない** |
| 6 | `llm-d.ai/role` ラベル | KServe が付与（`both` / `prefill` / `decode`）。Grafana の `role` はそのまま使用 |
| 7 | リクエスト ID がログに出るか | `x-request-id` は EPP のログにだけ出る。sim は独自 ID を振るため、**Prefill / Decode のログは時刻順で対応付けて見せる**。routing sidecar は既定の詳細度ではリクエストログを出さない |
| 8 | Gateway の Service が LoadBalancer を作るか | `AgentgatewayParameters` で `type: ClusterIP` を指定し、LB が作られないことを確認（未指定時の既定動作は未検証） |
| 9 | terraform-oci-oke v5.5.1 の変数名 | `cluster_type` / `cni_type` / `control_plane_is_public` / `control_plane_allowed_cidrs` / `create_bastion` / `create_operator` / `create_iam_resources` / `worker_pools` / `load_balancers` で確認。`subnets` で未使用サブネット（bastion / operator / int_lb / pods）を作らない |
| 9b | リージョンを持たない構成で `oci.home` を満たせるか | `oci_identity_region_subscriptions`（`is_home_region`）でホームリージョンを動的に解決（モジュール同梱の ORM サンプルと同じ方式）。ORM コンソールは `tenancy_ocid` / `region` を自動入力するが、**CLI/API でスタックを作る場合は明示が必要**なので `10-infra-up.sh` が OCI CLI プロファイルから渡す |
| 10 | amd64 での各イメージ | sim / EPP（`llm-d-router-endpoint-picker:v0.9.0`）/ disagg-sidecar（v0.9.0）とも E5.Flex で起動 |
| 11 | kube-prometheus-stack | `92.3.0` に固定 |
| 12 | E5.Flex の OCPU 上限 | 検証テナンシでは 6 OCPU で問題なし（テナンシにより要確認） |
| 13 | `spec.annotations` / `spec.prefill.annotations` / `spec.router.scheduler.annotations` の伝播 | v1alpha2 でも Pod に伝播（EPP の metrics は `--metrics-endpoint-auth=false` で取得可） |

その他の注意点:

- **OKE（K8s ≥ 1.34）の CRI-O は short name のイメージを拒否**します（`short name mode is enforcing`）。KServe チャートの既定イメージ `kserve/llmisvc-controller` が該当するため、`20-platform-install.sh` で `docker.io/` を付けています。
- **Helm 4 は server-side apply** のため、2 回目の `kserve-runtime-configs` 更新が KServe コントローラーと競合します。Helm 4 のときだけ `--force-conflicts` を付けています。
- EPP の inline config の `apiVersion` は KServe v0.20.0 が生成するものに合わせ `inference.networking.x-k8s.io/v1alpha1` を使っています。
- KServe v0.20.0 の scheduler preset には UDS tokenizer サイドカーが含まれますが、本デモの構成では EPP Pod は `main` 1 コンテナで起動しました。
- Deploy to OCI ボタン相当の確認として、`stack.zip`（`schema.yaml` 込み）から別スタックを作成し Plan（51 リソース追加）が通ることを確認済みです。GitHub Release 経由のボタン動作そのものは、Release 公開後に確認してください（未検証）。
