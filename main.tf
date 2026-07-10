################################################################################
# Remote outputs from eks-infra-vcs
################################################################################

data "tfe_outputs" "infra" {
  organization = var.tfc_organization
  workspace    = var.infra_workspace
}

locals {
  cluster_name = data.tfe_outputs.infra.values.cluster_name
  cluster_ep   = data.tfe_outputs.infra.values.cluster_endpoint
  cluster_ca   = data.tfe_outputs.infra.values.cluster_certificate_authority_data
  aws_region   = data.tfe_outputs.infra.values.aws_region
  vault_fqdn   = "${var.vault_hostname}.${var.base_domain}"

  # Image coordinates — differ between community and enterprise
  vault_image_repo = var.vault_edition == "enterprise" ? "hashicorp/vault-enterprise" : "hashicorp/vault"
  vault_image_tag  = var.vault_edition == "enterprise" ? "${var.vault_chart_version}-ent" : var.vault_chart_version
}

################################################################################
# Providers
################################################################################

provider "aws" {
  region = local.aws_region
}

provider "kubernetes" {
  host                   = local.cluster_ep
  cluster_ca_certificate = base64decode(local.cluster_ca)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.aws_region]
  }
}

# helm 3.x: kubernetes is an attribute (object), not a block — use = { ... }
provider "helm" {
  kubernetes = {
    host                   = local.cluster_ep
    cluster_ca_certificate = base64decode(local.cluster_ca)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--region", local.aws_region]
    }
  }
}

provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

################################################################################
# Route 53 — hosted zone for DNS-01 challenge
################################################################################

data "aws_route53_zone" "base" {
  name         = var.base_domain
  private_zone = false
}

################################################################################
# ACME — Let's Encrypt certificate via DNS-01 (Route 53)
################################################################################

resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "main" {
  email_address   = var.acme_email
  account_key_pem = tls_private_key.acme_account.private_key_pem
}

resource "acme_certificate" "vault" {
  account_key_pem           = acme_registration.main.account_key_pem
  common_name               = local.vault_fqdn
  subject_alternative_names = [local.vault_fqdn]
  key_type                  = "2048"

  dns_challenge {
    provider = "route53"
    config = {
      AWS_HOSTED_ZONE_ID = data.aws_route53_zone.base.zone_id
    }
  }
}

################################################################################
# Kubernetes namespace
################################################################################

resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.vault_namespace
    labels = {
      environment = var.environment
      owner       = var.owner
      project     = var.project
    }
  }
}

################################################################################
# Kubernetes TLS secret — mounted by the Vault listener
################################################################################

resource "kubernetes_secret" "vault_tls" {
  metadata {
    name      = "vault-tls"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = "${acme_certificate.vault.certificate_pem}${acme_certificate.vault.issuer_pem}"
    "tls.key" = acme_certificate.vault.private_key_pem
  }
}

################################################################################
# Vault Enterprise licence secret (skipped for community edition)
################################################################################

resource "kubernetes_secret" "vault_license" {
  count = var.vault_edition == "enterprise" ? 1 : 0

  metadata {
    name      = "vault-ent-license"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  data = {
    license = var.vault_enterprise_license
  }
}

################################################################################
# Helm — HashiCorp Vault
# Values are rendered from vault-values.yaml.tpl via templatefile().
# Edit the template file to change chart configuration — do not add set{} blocks.
################################################################################

resource "helm_release" "vault" {
  name             = "vault"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = var.vault_chart_version
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    templatefile("${path.module}/vault-values.yaml.tpl", {
      vault_image_repo    = local.vault_image_repo
      vault_image_tag     = local.vault_image_tag
      vault_replicas      = var.vault_replicas
      ha_enabled          = var.vault_replicas > 1
      tls_secret_name     = kubernetes_secret.vault_tls.metadata[0].name
      vault_edition       = var.vault_edition
      vault_fqdn          = local.vault_fqdn
      license_secret_name = var.vault_edition == "enterprise" ? kubernetes_secret.vault_license[0].metadata[0].name : ""
    })
  ]

  depends_on = [
    kubernetes_secret.vault_tls,
    kubernetes_namespace.vault,
  ]
}

################################################################################
# Route 53 — CNAME pointing to the Vault NLB
################################################################################

data "kubernetes_service" "vault_lb" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  depends_on = [helm_release.vault]
}

resource "aws_route53_record" "vault" {
  zone_id = data.aws_route53_zone.base.zone_id
  name    = local.vault_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [data.kubernetes_service.vault_lb.status[0].load_balancer[0].ingress[0].hostname]

  depends_on = [helm_release.vault]
}
