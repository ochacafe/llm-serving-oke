output "cluster_id" {
  description = "OKE クラスタ OCID"
  value       = module.oke.cluster_id
}

output "bastion_public_ip" {
  description = "踏み台（bastion）のパブリック IP"
  value       = module.oke.bastion_public_ip
}

output "operator_private_ip" {
  description = "操作用インスタンス（operator）のプライベート IP"
  value       = module.oke.operator_private_ip
}

output "ssh_to_operator" {
  description = "operator への SSH コマンド（秘密鍵は -i で指定）"
  value       = "ssh -J opc@${module.oke.bastion_public_ip} opc@${module.oke.operator_private_ip}"
}
