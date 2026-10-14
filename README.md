# llm-serving-oke — vLLM / llm-d / KServe 入門デモ（OKE, GPU なし）

1 つの `LLMInferenceService` の YAML を少しずつ書き足して、
**KServe → llm-d スケジューラ → Prefill/Decode 分離** へと進化させる 15〜20 分のデモです。
推論エンジンは GPU 不要の vLLM 互換シミュレーター [llm-d-inference-sim](https://github.com/llm-d/llm-d-inference-sim) を使い、
OCI Container Engine for Kubernetes (OKE) の CPU ノードだけで動きます。

| Step | 見せること | 書き足す YAML |
|---|---|---|
| 1 | YAML 1 枚から Deployment / Service / HTTPRoute が自動生成される | — |
| 2 | 普通の L7 LB（P2C）と llm-d スケジューラ（prefix cache 考慮）を同じ負荷で比較 | `router.scheduler` |
| 3 | Prefill Pod → Decode Pod のリレーと、Prefill だけの独立スケール | `prefill:`（EPP 設定は KServe 既定の P/D 用に任せる） |
| 締め | `diff` で Step 1 → 2 → 3 の差分 | — |

```
手元の端末 ──SSH(22)──▶ bastion（公開サブネット）──SSH──▶ operator（プライベート、kubectl / helm / OCI CLI）
                                                              │ プライベート API エンドポイント
                                                              ▼
                     OKE ── agentgateway (Gateway: kserve-ingress-gateway)
                              ├─ HTTPRoute ─▶ Service ─▶ sim-baseline ×4      (P2C)
                              ├─ HTTPRoute ─▶ InferencePool ─▶ EPP ─▶ sim-llmd ×4
                              └─ HTTPRoute ─▶ InferencePool ─▶ EPP ─▶ sim-pd (prefill ×2 / decode ×2 + routing sidecar)
                          Grafana ◀── Prometheus（Pod アノテーションで 5 秒間隔 scrape）

手元のブラウザ ──SSH トンネル──▶ operator ──port-forward──▶ Grafana :3000 / Gateway :8080
```

Kubernetes API はプライベートで、クラスタの操作はすべて operator インスタンス上で行います。
`make` は手元で打てば、スクリプトが operator にリポジトリを同期して SSH 越しに実行します。
手元から出ていく通信は SSH（22）と HTTPS（443）だけなので、送信ポートが制限されたネットワークでも使えます。

---

## 構成

| パス | 内容 |
|---|---|
| `terraform/` | OKE（Basic / flannel / E5.Flex ×3）と踏み台（bastion / operator）を作る **OCI Resource Manager スタック** |
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
| SSH 鍵 | `~/.ssh/llm-serving-oke`（初回に自動生成。公開鍵だけを ORM のスタック変数で渡す） |
| operator の OCI 認証 | インスタンス・プリンシパル（operator 1 台だけを対象にした動的グループとポリシー）。インスタンスに API キーを置かない |
| Terraform state | OCI Resource Manager が管理（手元に tfstate を作らない） |
| ORM スタック ID・SSH 設定 | `.state/`（`.gitignore` 済み） |
| kubeconfig | operator 上の `~/llm-serving-oke/kubeconfig`（トークンはインスタンス・プリンシパルで都度発行） |
| Grafana 管理者パスワード | クラスタ内でランダム生成した Secret のみ（匿名閲覧 ON なので通常は不要） |

Kubernetes API エンドポイントはプライベート、bastion への SSH は利用者の IP（`admin_cidrs`）だけに開放します。
Gateway / Grafana は LoadBalancer を作らず、operator 上の port-forward と SSH トンネルでのみアクセスします。
CI（`.github/workflows/ci.yml`）で gitleaks と OCID 混入チェックを実行します。

---

## 前提

- OCI テナンシ（`VM.Standard.E5.Flex` をワーカー 6 + bastion 1 + operator 1 の計 8 OCPU 使えること）と、OKE / VCN / インスタンスを作成できるコンパートメント
- 実行ユーザーが **動的グループ（テナンシ直下）とポリシー（対象コンパートメント）を作成できる IAM 権限**（operator のインスタンス・プリンシパル用）
- 手元: `oci`（設定済みプロファイル）, `jq`, `curl`, `zip`, `ssh`, `tar`。kubectl / helm / stern / k9s は operator に自動で入る
- 任意: [`uv`](https://docs.astral.sh/uv/)（loadgen を手元で動かす `LOADGEN_MODE=local` の場合のみ）

```bash
cp .env.example .env   # OCI_COMPARTMENT_OCID を設定
make check             # = bash scripts/00-check-prereqs.sh
```

## 1. OKE と踏み台を作る（OCI Resource Manager）

```bash
make up                # = bash scripts/10-infra-up.sh
```

1. 手元のグローバル IP を検出して `admin_cidrs` にする（`ADMIN_CIDRS=1.2.3.4/32,...` で上書き可）
2. SSH 鍵 `~/.ssh/llm-serving-oke` が無ければ作る（`SSH_KEY_PATH` で変更可）
3. `terraform/` から `stack.zip` を作り、ORM スタックを作成（2 回目以降は更新）
4. ORM の Apply ジョブを実行（初回 20 分前後）
5. `.state/ssh_config` に bastion → operator の SSH 設定を書き出し、operator の初期化（cloud-init）を待つ
6. operator にリポジトリを同期し、インスタンス・プリンシパルで kubeconfig を作ってノード Ready を待つ

リージョンは OCI CLI プロファイルのものを使います（コードにリージョン名は持たせていません）。
**手元のグローバル IP が変わったら `make up` を再実行**すれば許可 CIDR だけ更新されます。

operator に直接入って kubectl / k9s / stern を使う場合は `make ssh` です。

## 2. プラットフォームを入れる

```bash
make platform   # = bash scripts/20-platform-install.sh（冪等）
make pf         # = bash scripts/port-forward.sh（operator 上で port-forward + 手元へ SSH トンネル）
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
ターミナル 2 枚（デモ用 / Step 3 のログ用）とブラウザ（Grafana）を使います。
`make demo-*` は手元で打つと operator 上で実行され（SSH 越しの対話実行）、Grafana は `make pf` の SSH トンネル経由で手元のブラウザから開けます。
事前に `make preflight` を一度通しておくと、全ノードにイメージがキャッシュされ、デモ中の Pod 起動が速くなります。

### デモの流れ

#### Step 1: YAML 1 枚から何ができるか（`make demo-1`、4〜5 分）

1. `manifests/step1-baseline.yaml` を表示する（モデル名・レプリカ数 4・sim コンテナだけの `LLMInferenceService`）
2. `kubectl apply` → Ready 待ち
3. KServe が自動生成したリソース（Deployment / Service / HTTPRoute など）をツリー表示
4. Gateway 経由で `curl` し、OpenAI 互換のレスポンスが返ることを確認
5. 同じリクエストを 6 回送り、`x-inference-pod` ヘッダーで毎回別の Pod が応答する（普通の L7 LB で振り分けられている）ことを確認

#### Step 2: 普通の LB と llm-d スケジューラの比較（`make demo-2`、7〜8 分）

1. Step 1 との `diff` を表示（`router.scheduler` を足しただけ）
2. 適用 → InferencePool と EPP（`sim-llmd-kserve-router-scheduler`）が増えたことをツリーで確認
3. Grafana の比較ダッシュボード（`http://localhost:3000/d/routing`）を開く
4. Enter で負荷開始。テナント 10 社分、各約 4,000 トークンのシステムプロンプトを付けたリクエストを、両方へ同時に送る（5 分間）

ターミナルには左右 2 列のライブ画面が出ます（値は検証時の実測）。

| 画面の項目 | 普通の LB（左） | llm-d（右） |
|---|---|---|
| TTFT p50 | 約 1,250 ms | 約 45 ms |
| テナント × Pod の表 | 全マスに散らばる | 各テナントが 1 つの Pod に固まる |
| Grafana のキャッシュヒット率 | 約 30% | 約 90% |

最初の 30 秒ほどは両方ともキャッシュが空なので差が出ず、1 分ほどで差が開きます。
llm-d は同じプロンプトの続きを、KV キャッシュを持っている Pod に送るため TTFT が短くなります。

#### Step 3: Prefill / Decode 分離（`make demo-3`、5〜6 分）

始める前に、2 枚目のターミナルで `make demo-3-logs` を流しておきます（EPP / Prefill / Decode のログ）。

1. Step 2 との `diff` を表示（`prefill:` を足し、EPP の設定は KServe 既定の P/D 用に任せる）
2. 適用 → Pod 一覧の ROLE 列で `prefill` ×2 と `decode` ×2 に分かれていることを確認
3. Decode Pod のコンテナ一覧に `llm-d-routing-sidecar` が自動で注入されていることを確認
4. 1 リクエストずつ 3 回送る。ログ側に次の順で行が出る
   - EPP が受信
   - Prefill Pod が受信（約 1.5 秒）
   - Decode Pod が受信 → 完了

   リクエスト ID は EPP のログにしか出ないため、時刻の並びで Prefill → Decode のリレーを確認します。
5. `kubectl patch` で `prefill.replicas` を 4 にする。Prefill Pod だけが 2 → 4 台に増え、Decode Pod は作り直されない。
   入力が長いワークロードでは Prefill だけを増強できる、という点を示します。
   Grafana の P/D ダッシュボード（`http://localhost:3000/d/pd`）では、ロール別の Pod 数の線が変わります。

#### 締め（`make demo-diff`、1 分）

Step 1 → 2 → 3 の差分を続けて表示します。単体の vLLM 相当から P/D 分離クラスタまで、YAML の差分はこれだけです。

もう一度最初から行う場合は `make reset` で Step 1 前の状態に戻します。

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

---

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `make` が SSH 接続できない | 手元の IP が変わった可能性。`make up` で許可 CIDR を更新 |
| operator で `kubectl` が認可エラー | 動的グループ / ポリシーの反映待ち（数分）。`make up` を再実行すると kubeconfig 生成を再試行する |
| Grafana が開けない | `make pf` を再実行（operator 側の port-forward は切断時に自動で張り直し、手元の SSH トンネルも張り直す） |
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
| 9b | リージョンを持たない構成で `oci.home` を満たせるか | `oci_identity_region_subscriptions`（`is_home_region`）でホームリージョンを動的に解決（モジュール同梱の ORM サンプルと同じ方式）。ORM の CLI/API でスタックを作る場合は `tenancy_ocid` / `region` の明示が必要なので `10-infra-up.sh` が OCI CLI プロファイルから渡す |
| 10 | amd64 での各イメージ | sim / EPP（`llm-d-router-endpoint-picker:v0.9.0`）/ disagg-sidecar（v0.9.0）とも E5.Flex で起動 |
| 11 | kube-prometheus-stack | `92.3.0` に固定 |
| 12 | E5.Flex の OCPU 上限 | 検証テナンシでは 6 OCPU で問題なし（テナンシにより要確認） |
| 13 | `spec.annotations` / `spec.prefill.annotations` / `spec.router.scheduler.annotations` の伝播 | v1alpha2 でも Pod に伝播（EPP の metrics は `--metrics-endpoint-auth=false` で取得可） |

その他の注意点:

- **OKE（K8s ≥ 1.34）の CRI-O は short name のイメージを拒否**します（`short name mode is enforcing`）。KServe チャートの既定イメージ `kserve/llmisvc-controller` が該当するため、`20-platform-install.sh` で `docker.io/` を付けています。
- **Helm 4 は server-side apply** のため、2 回目の `kserve-runtime-configs` 更新が KServe コントローラーと競合します。Helm 4 のときだけ `--force-conflicts` を付けています。
- EPP の inline config の `apiVersion` は KServe v0.20.0 が生成するものに合わせ `inference.networking.x-k8s.io/v1alpha1` を使っています。
- KServe v0.20.0 の scheduler preset には UDS tokenizer サイドカーが含まれますが、本デモの構成では EPP Pod は `main` 1 コンテナで起動しました。
