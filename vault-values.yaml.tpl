################################################################################
# vault-values.yaml.tpl
# Helm values for the HashiCorp Vault chart.
# Rendered by templatefile() in main.tf — do NOT hand-edit the .tf set{} blocks.
################################################################################

global:
  tlsDisable: false

server:
  image:
    repository: "${vault_image_repo}"
    tag:        "${vault_image_tag}"

  replicas: ${vault_replicas}

  # Extra environment variables
  extraEnvironmentVars:
    VAULT_ADDR:     "https://127.0.0.1:8200"
    VAULT_API_ADDR: "https://$(POD_IP):8200"

  # HCL listener stanza — injected verbatim via extraConfig
  extraConfig: |
    listener "tcp" {
      address       = "0.0.0.0:8200"
      tls_cert_file = "/vault/tls/tls.crt"
      tls_key_file  = "/vault/tls/tls.key"
    }

  # Mount the Let's Encrypt TLS secret
  volumes:
    - name: vault-tls
      secret:
        secretName: "${tls_secret_name}"

  volumeMounts:
    - name:      vault-tls
      mountPath: /vault/tls
      readOnly:  true

  # HA Raft
  ha:
    enabled:  ${ha_enabled}
    replicas: ${vault_replicas}
    raft:
      enabled: true
      config: |
        ui = true

        listener "tcp" {
          address       = "0.0.0.0:8200"
          tls_cert_file = "/vault/tls/tls.crt"
          tls_key_file  = "/vault/tls/tls.key"
        }

        storage "raft" {
          path = "/vault/data"
        }

        service_registration "kubernetes" {}

  # Expose Vault via an internet-facing AWS NLB
  service:
    type: LoadBalancer
    annotations:
      service.beta.kubernetes.io/aws-load-balancer-type:   "nlb"
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

%{ if vault_edition == "enterprise" ~}
  # Enterprise licence secret — only rendered for vault_edition = enterprise
  enterpriseLicense:
    secretName: "${license_secret_name}"
    secretKey:  license
%{ endif ~}

ui:
  enabled: true
