# ---- ORM の標準変数（scripts/10-infra-up.sh が OCI CLI プロファイルから渡す） ----
variable "tenancy_ocid" {
  type        = string
  description = "テナンシ OCID（10-infra-up.sh が OCI CLI プロファイルから設定）"
}

variable "region" {
  type        = string
  description = "デプロイ先リージョン（10-infra-up.sh が OCI CLI プロファイルから設定）"
}

variable "compartment_ocid" {
  type        = string
  description = "OKE / VCN を作成するコンパートメント"
}

# ---- デモ用パラメータ ----
variable "cluster_name" {
  type    = string
  default = "llm-demo"
}

variable "kubernetes_version" {
  type    = string
  default = "v1.35.2"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Kubernetes API エンドポイントへのアクセスを許可する CIDR（利用者のグローバル IP/32 など）"

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs には 1 つ以上の有効な CIDR（例: 203.0.113.10/32）を指定してください。"
  }
}

variable "worker_count" {
  type    = number
  default = 3
}

variable "worker_shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}

variable "worker_ocpus" {
  type    = number
  default = 2
}

variable "worker_memory_gb" {
  type    = number
  default = 16
}

variable "worker_boot_volume_gb" {
  type    = number
  default = 50
}
