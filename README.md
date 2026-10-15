# llm-serving-oke — vLLM / llm-d / KServe 入門デモ（OKE, GPU なし）

1 つの `LLMInferenceService` の YAML を少しずつ書き足して、
**KServe → llm-d スケジューラ → Prefill/Decode 分離** へと進化させるデモです。
推論エンジンは GPU 不要の vLLM 互換シミュレーター [llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim) を使い、
OCI Container Engine for Kubernetes (OKE) の CPU ノードだけで動きます。

| Step | 見せること | 書き足す YAML |
|---|---|---|
| 1 | YAML 1 枚から Deployment / Service / HTTPRoute が自動生成される | — |
| 2 | 普通の L7 LB と llm-d スケジューラ（prefix cache 考慮）を同じ負荷で比較し、TTFT の差を見る | `router.scheduler` |
| 3 | Prefill Pod → Decode Pod のリレーと、Prefill だけの独立スケール | `prefill:` |

## 使い方

### 準備

- OCI CLI の設定（`~/.oci/config`。既定はプロファイル `DEFAULT`、リージョンもここから決まる）
- 手元に `oci` / `jq` / `curl` / `zip` / `ssh` / `tar`（kubectl / helm は踏み台インスタンスに自動で入る）
- OKE・VCN・インスタンスを作るコンパートメントと、動的グループ / ポリシーを作成できる IAM 権限

```bash
cp .env.example .env   # OCI_COMPARTMENT_OCID を設定
make check             # 前提ツールと OCI CLI 設定の確認
```

### 環境を作る

リポジトリ直下で実行します。

```bash
make up          # OKE と踏み台（bastion / operator）を OCI Resource Manager で作成（20 分前後）
make platform    # KServe / agentgateway / Prometheus・Grafana を導入
make pf          # Gateway と Grafana を手元に転送（http://localhost:3000）
make preflight   # Step 1〜3 を自動で通して動作確認（約 10 分）
```

クラスタの操作は踏み台の operator インスタンス上で行われます（`make` は手元で打てば SSH 越しに実行されます）。
operator に直接入る場合は `make ssh` です。
SSH が通らない場合は `.env` に `ADMIN_CIDRS=0.0.0.0/0` を設定して `make up` を再実行してください。

### デモを実行する

各コマンドは「次のコマンドを表示 → Enter で実行」の形式で進みます。

```bash
make demo-1       # Step 1
make demo-2       # Step 2（Grafana: http://localhost:3000/d/routing）
make demo-3       # Step 3（別ターミナルで make demo-3-logs、Grafana: http://localhost:3000/d/pd）
make demo-diff    # Step 1 → 2 → 3 の YAML 差分
make reset        # 最初からやり直す
```

- **Step 1**: YAML を apply し、自動生成されたリソースと、Gateway 経由のリクエストが毎回別の Pod に振り分けられる様子を見る
- **Step 2**: 10 テナント分の長いプロンプトを両方へ同時に流す。普通の LB はテナントが全 Pod に散らばり TTFT が約 1.2 秒、llm-d はテナントごとに Pod が固定されキャッシュに当たり TTFT が約 45 ms になる
- **Step 3**: Prefill / Decode の Pod が分かれ、1 リクエストのログが Prefill → Decode の順に流れる。`prefill.replicas` を変えると Prefill Pod だけが増える

### 片付け

```bash
make down        # OCI 上のリソースをすべて削除
```
