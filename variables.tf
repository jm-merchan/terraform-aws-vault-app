################################################################################
# HCP Terraform
################################################################################

variable "tfc_organization" {
  description = "HCP Terraform organisation name"
  type        = string
  default     = "jose-merchan"
}

variable "infra_workspace" {
  description = "Name of the upstream EKS infrastructure workspace"
  type        = string
  default     = "eks-infra-vcs"
}

################################################################################
# Mandatory tags
################################################################################

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Team or individual that owns this deployment"
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost centre for billing attribution"
  type        = string
  default     = "CC-DEV1"
}

variable "project" {
  description = "Project identifier"
  type        = string
  default     = "vault"
}

################################################################################
# DNS / TLS
################################################################################

variable "base_domain" {
  description = "Base DNS zone managed in Route 53 (e.g. jose-merchan.sbx.hashidemos.io)"
  type        = string
  default     = "jose-merchan.sbx.hashidemos.io"
}

variable "vault_hostname" {
  description = "Hostname for Vault (prepended to base_domain)"
  type        = string
  default     = "vault"
}

variable "acme_email" {
  description = "Contact e-mail for the ACME account (Let's Encrypt notifications)"
  type        = string
  default     = "jose.merchan@hashicorp.com"
}

################################################################################
# Vault
################################################################################

variable "vault_edition" {
  description = "Vault edition to deploy: 'community' or 'enterprise'"
  type        = string
  default     = "community"

  validation {
    condition     = contains(["community", "enterprise"], var.vault_edition)
    error_message = "vault_edition must be 'community' or 'enterprise'."
  }
}

variable "vault_chart_version" {
  description = "Helm chart version for HashiCorp Vault (https://github.com/hashicorp/vault-helm)"
  type        = string
  default     = "0.29.1"
}

variable "vault_enterprise_license" {
  description = "Vault Enterprise licence string (only required when vault_edition = 'enterprise')"
  type        = string
  default     = ""
  sensitive   = true
}

variable "vault_namespace" {
  description = "Kubernetes namespace to deploy Vault into"
  type        = string
  default     = "vault"
}

variable "vault_replicas" {
  description = "Number of Vault server replicas (HA Raft)"
  type        = number
  default     = 3
}
