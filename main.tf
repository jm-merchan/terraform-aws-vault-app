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

  # Select image repo based on edition
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

# ACME provider — staging first, switch to production by changing server_url
provider "acme" {
  server_url = "https://acme-v02.api.letsencrypt.org/directory"
}

################################################################################
# Route 53 — look up the hosted zone for DNS-01 challenge
################################################################################

data "aws_route53_zone" "base" {
  name         = var.base_domain
  private_zone = false
}

################################################################################
# ACME — Let's Encrypt TLS certificate via DNS-01 (Route 53)
################################################################################

# One-time ACME account registration (private key stored in state)
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
  # key_type "2048" = RSA-2048; ACME provider generates the cert key itself
  key_type = "2048"

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
# Kubernetes TLS secret — mounted by Vault listener
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
# Vault Enterprise licence secret (no-op when community)
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
# Route 53 — DNS record pointing to Vault NLB
# Created after Helm deploy so the LB hostname is known
################################################################################

resource "aws_route53_record" "vault" {
  zone_id = data.aws_route53_zone.base.zone_id
  name    = local.vault_fqdn
  type    = "CNAME"
  ttl     = 60
  # The NLB hostname is emitted by Helm via the service status
  records = [data.kubernetes_service.vault_lb.status[0].load_balancer[0].ingress[0].hostname]

  depends_on = [helm_release.vault]
}

# Read back the Vault service to get the provisioned NLB hostname
data "kubernetes_service" "vault_lb" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  depends_on = [helm_release.vault]
}

################################################################################
# Helm — HashiCorp Vault
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

  # --- Global ---
  set {
    name  = "global.tlsDisable"
    value = "false"
  }

  # --- Server ---
  set {
    name  = "server.image.repository"
    value = local.vault_image_repo
  }
  set {
    name  = "server.image.tag"
    value = local.vault_image_tag
  }
  set {
    name  = "server.replicas"
    value = tostring(var.vault_replicas)
  }

  # TLS cert from the kubernetes secret
  set {
    name  = "server.volumes[0].name"
    value = "vault-tls"
  }
  set {
    name  = "server.volumes[0].secret.secretName"
    value = kubernetes_secret.vault_tls.metadata[0].name
  }
  set {
    name  = "server.volumeMounts[0].name"
    value = "vault-tls"
  }
  set {
    name  = "server.volumeMounts[0].mountPath"
    value = "/vault/tls"
  }
  set {
    name  = "server.volumeMounts[0].readOnly"
    value = "true"
  }

  # HA Raft storage
  set {
    name  = "server.ha.enabled"
    value = tostring(var.vault_replicas > 1)
  }
  set {
    name  = "server.ha.replicas"
    value = tostring(var.vault_replicas)
  }
  set {
    name  = "server.ha.raft.enabled"
    value = "true"
  }

  # Listener config — HTTPS on 8200 with the Let's Encrypt cert
  set {
    name  = "server.extraEnvironmentVars.VAULT_ADDR"
    value = "https://127.0.0.1:8200"
  }
  set {
    name  = "server.extraEnvironmentVars.VAULT_API_ADDR"
    value = "https://$(POD_IP):8200"
  }

  # Override listener to use the mounted TLS cert
  set {
    name  = "server.extraConfig"
    value = <<-EOT
      listener "tcp" {
        address       = "0.0.0.0:8200"
        tls_cert_file = "/vault/tls/tls.crt"
        tls_key_file  = "/vault/tls/tls.key"
      }
    EOT
  }

  # Enterprise licence (injected via env var from secret)
  dynamic "set" {
    for_each = var.vault_edition == "enterprise" ? [1] : []
    content {
      name  = "server.enterpriseLicense.secretName"
      value = kubernetes_secret.vault_license[0].metadata[0].name
    }
  }

  # --- UI ---
  set {
    name  = "ui.enabled"
    value = "true"
  }

  # --- Service — internet-facing AWS NLB ---
  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  depends_on = [
    kubernetes_secret.vault_tls,
    kubernetes_namespace.vault,
  ]
}
