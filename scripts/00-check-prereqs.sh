#!/usr/bin/env bash
# 前提ツールと OCI CLI 設定の確認
source "$(dirname "$0")/lib.sh"

fail=0
for c in oci kubectl helm jq curl zip openssl uv; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else ng "$c が見つかりません"; fail=1; fi
done
for c in stern bat delta; do
  command -v "$c" >/dev/null 2>&1 && ok "$c（任意）" || warn "$c（任意）なし: brew install $c"
done
kubectl tree --help >/dev/null 2>&1 && ok "kubectl tree（任意）" || warn "kubectl tree（任意）なし: kubectl krew install tree（無くてもフォールバック表示します）"

region="$(oci_profile_value region || true)"
if [[ -n "${region}" ]]; then ok "OCI CLI プロファイル ${OCI_CLI_PROFILE}: region=${region}"; else ng "OCI CLI プロファイル ${OCI_CLI_PROFILE} が読めません"; fail=1; fi
if oci os ns get >/dev/null 2>&1; then ok "OCI API 認証"; else ng "OCI API 認証に失敗（oci setup config / プロファイルを確認）"; fail=1; fi
[[ -n "${OCI_COMPARTMENT_OCID:-}" ]] && ok "OCI_COMPARTMENT_OCID 設定済み" || warn "OCI_COMPARTMENT_OCID 未設定（.env.example 参照。--cluster-id 利用時は不要）"

exit "${fail}"
