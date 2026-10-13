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

  # コストと手間を最小化: bastion / operator / IAM は作らない
  create_bastion       = false
  create_operator      = false
  create_iam_resources = false

  # Network
  vcn_name                    = "${var.cluster_name}-vcn"
  vcn_dns_label               = "llmdemo"
  load_balancers              = "public"
  preferred_load_balancer     = "public"
  control_plane_allowed_cidrs = var.admin_cidrs
  allow_worker_ssh_access     = false
  assign_dns                  = true
  # 使わないサブネットは作らない（flannel なので pods サブネットも不要）
  subnets = {
    bastion  = { create = "never" }
    operator = { create = "never" }
    int_lb   = { create = "never" }
    pods     = { create = "never" }
    cp       = { newbits = 13 }
    pub_lb   = { newbits = 11 }
    workers  = { newbits = 4 }
  }

  # Cluster
  cluster_name                      = var.cluster_name
  cluster_type                      = "basic"
  cni_type                          = "flannel"
  kubernetes_version                = var.kubernetes_version
  control_plane_is_public           = true
  assign_public_ip_to_control_plane = true

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
    cluster = { project = "llm-serving-oke" }
    network = { project = "llm-serving-oke" }
    workers = { project = "llm-serving-oke" }
  }

  output_detail = true
}
