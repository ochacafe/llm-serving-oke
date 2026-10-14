# operator インスタンス 1 台だけにクラスタ操作権限を与える（インスタンス・プリンシパル）。
# 動的グループはテナンシ直下、ポリシーは対象コンパートメントに、ホームリージョンで作成する。

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  operator_dynamic_group_name = "${var.cluster_name}-operator-${random_string.suffix.result}"
}

resource "oci_identity_dynamic_group" "operator" {
  provider       = oci.home
  compartment_id = var.tenancy_ocid
  name           = local.operator_dynamic_group_name
  description    = "llm-serving-oke: operator instance of ${var.cluster_name}"
  matching_rule  = "ALL {instance.id = '${module.oke.operator_id}'}"
  freeform_tags  = { project = "llm-serving-oke" }
}

resource "oci_identity_policy" "operator" {
  provider       = oci.home
  compartment_id = var.compartment_ocid
  name           = "${local.operator_dynamic_group_name}-policy"
  description    = "llm-serving-oke: allow operator instance to manage the OKE cluster"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.operator.name} to manage cluster-family in compartment id ${var.compartment_ocid}",
  ]
  freeform_tags = { project = "llm-serving-oke" }
}
