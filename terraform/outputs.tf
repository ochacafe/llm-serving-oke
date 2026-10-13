output "cluster_id" {
  description = "OKE クラスタ OCID"
  value       = module.oke.cluster_id
}

output "kubeconfig_command" {
  description = "手元で kubeconfig を作るコマンド（scripts/10-infra-up.sh --cluster-id でも可）"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${module.oke.cluster_id} --region ${var.region} --file ./kubeconfig --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT"
}
