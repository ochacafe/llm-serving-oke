terraform {
  # OCI Resource Manager では Terraform 1.5.x で実行する（10-infra-up.sh が指定）
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source                = "oracle/oci"
      version               = ">= 8.14.0"
      configuration_aliases = [oci.home]
    }
  }
}
