output "vault_url" {
  description = "Public HTTPS URL of the Vault cluster"
  value       = "https://${local.vault_fqdn}:8200"
}

output "vault_ui_url" {
  description = "Public HTTPS URL of the Vault UI"
  value       = "https://${local.vault_fqdn}:8200/ui"
}

output "vault_load_balancer_hostname" {
  description = "AWS NLB hostname assigned to the Vault service"
  value       = data.kubernetes_service.vault_lb.status[0].load_balancer[0].ingress[0].hostname
}

output "vault_namespace" {
  description = "Kubernetes namespace where Vault is deployed"
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "certificate_expiry" {
  description = "Expiry date of the Let's Encrypt certificate"
  value       = acme_certificate.vault.certificate_not_after
}
