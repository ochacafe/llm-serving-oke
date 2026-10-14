module "oke" {
  source  = "oracle-terraform-modules/oke/oci"
  version = "5.5.1"

  providers = {
    oci      = oci
    oci.home = oci.home
  }

  tenancy_id     = var.tenancy_ocid
  compartment_id = var.compartment_ocid
  region         = var.region
  home_region    = local.home_region

  # 操作は踏み台経由: bastion（公開・SSH のみ）→ operator（プライベート・kubectl/helm/OCI CLI）
  # モジュールの IAM は「コンパートメント内の全インスタンス」を対象にするため使わず、iam.tf で operator 1 台に絞って作る
  create_iam_resources = false
  ssh_public_key       = var.ssh_public_key

  create_bastion          = true
  bastion_allowed_cidrs   = var.admin_cidrs
  bastion_await_cloudinit = false # ORM には秘密鍵を渡さないため SSH での完了待ちはしない
  bastion_shape = {
    shape            = var.worker_shape
    ocpus            = 1
    memory           = 4
    boot_volume_size = 50
  }

  create_operator          = true
  operator_await_cloudinit = false
  operator_install_helm    = true
  operator_install_stern   = true
  operator_install_k9s     = true
  operator_shape = {
    shape            = var.worker_shape
    ocpus            = 1
    memory           = 8
    boot_volume_size = 50
  }

  # Network
  vcn_name                = "${var.cluster_name}-vcn"
  vcn_dns_label           = "llmdemo"
  load_balancers          = "public"
  preferred_load_balancer = "public"
  allow_worker_ssh_access = false
  assign_dns              = true
  # 内部 LB 用と pods 用（flannel なので不要）のサブネットは作らない
  subnets = {
    bastion  = { newbits = 13 }
    operator = { newbits = 13 }
    int_lb   = { create = "never" }
    pods     = { create = "never" }
    cp       = { newbits = 13 }
    pub_lb   = { newbits = 11 }
    workers  = { newbits = 4 }
  }

  # Cluster
  cluster_name       = var.cluster_name
  cluster_type       = "basic"
  cni_type           = "flannel"
  kubernetes_version = var.kubernetes_version
  # API エンドポイントはプライベート。operator（VCN 内）からのみ到達できる
  control_plane_is_public           = false
  assign_public_ip_to_control_plane = false

  # Workers（OKE Oracle Linux 8 イメージ）
  worker_pool_mode        = "node-pool"
  worker_is_public        = false
  worker_image_type       = "oke"
  worker_image_os         = "Oracle Linux"
  worker_image_os_version = "8"
  worker_pools = {
    demo = {
      size             = var.worker_count
      shape            = var.worker_shape
      ocpus            = var.worker_ocpus
      memory           = var.worker_memory_gb
      boot_volume_size = var.worker_boot_volume_gb
    }
  }

  freeform_tags = {
    cluster  = { project = "llm-serving-oke" }
    network  = { project = "llm-serving-oke" }
    bastion  = { project = "llm-serving-oke" }
    operator = { project = "llm-serving-oke" }
    workers  = { project = "llm-serving-oke" }
  }

  output_detail = true
}
