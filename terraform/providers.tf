# 認証情報はここに書かない。
# - OCI Resource Manager が実行ユーザーの権限で provider を認証する。
# - region / tenancy_ocid / compartment_ocid は scripts/10-infra-up.sh がスタック変数として渡す。
# - リージョン名はコードに持たない（スタックを作成したリージョン = var.region）。

provider "oci" {
  region = var.region
}

# terraform-oci-oke モジュールはホームリージョン用の provider alias を要求する。
# IAM リソースは作らないが、ホームリージョンはテナンシから動的に解決する（リージョン名をハードコードしない）。
provider "oci" {
  alias  = "home"
  region = local.home_region
}

data "oci_identity_region_subscriptions" "home" {
  tenancy_id = var.tenancy_ocid
  filter {
    name   = "is_home_region"
    values = [true]
  }
}

locals {
  home_region = one(data.oci_identity_region_subscriptions.home.region_subscriptions[*].region_name)
}
