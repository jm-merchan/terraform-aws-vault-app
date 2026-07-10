################################################################################
# vault-values.yaml.tpl
# Helm values for the HashiCorp Vault chart (hashicorp/vault).
# Rendered by templatefile() in main.tf — do NOT add set{} blocks in .tf.
#
# Key design decisions:
#   - TLS termination at the Vault listener (not ingress/LB) using LE cert
#   - HA Raft with 3 replicas; retry_join uses the headless service (vault-internal)
#   - StorageClass gp3 — required for EKS 1.33+ (EBS CSI driver, not in-tree)
#   - POD_IP injected via Downward API so VAULT_API_ADDR is correct per-pod
################################################################################

global:
  tlsDisable: false

server:
  image:
    repository: "${vault_image_repo}"
    tag:        "${vault_image_tag}"

  # Extra environment variables
  # POD_IP is injected via Downward API (extraEnv below) so VAULT_API_ADDR
  # resolves to the correct per-pod IP at runtime.
  extraEnvironmentVars:
    VAULT_ADDR: "https://127.0.0.1:8200"

  # Inject POD_IP from the Downward API — referenced in ha.raft.config
  extraEnv:
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP

  # Mount the Let's Encrypt TLS secret
  volumes:
    - name: vault-tls
      secret:
        secretName: "${tls_secret_name}"

  volumeMounts:
    - name:      vault-tls
      mountPath: /vault/tls
      readOnly:  true

  # PVC for Raft data — one per pod, bound to an EBS gp3 volume.
  # gp3 is the correct StorageClass for EKS 1.33+ (provisioned by EBS CSI driver).
  # gp2 is the legacy in-tree class and may not exist in newer clusters.
  dataStorage:
    enabled:      true
    size:         10Gi
    storageClass: gp3
    accessMode:   ReadWriteOnce

  # HA Raft — all replica/listener/storage config lives here when ha.enabled=true.
  # server.replicas is IGNORED by the chart when ha.enabled=true; use ha.replicas only.
  ha:
    enabled:  ${ha_enabled}
    replicas: ${vault_replicas}

    raft:
      enabled:   true
      setNodeId: true

      config: |
        ui = true

        listener "tcp" {
          address       = "0.0.0.0:8200"
          cluster_address = "0.0.0.0:8201"
          tls_cert_file = "/vault/tls/tls.crt"
          tls_key_file  = "/vault/tls/tls.key"
        }

        storage "raft" {
          path    = "/vault/data"
          node_id = "$${POD_NAME}"

          # retry_join block per peer — uses the Kubernetes headless service
          # (vault-internal) so pods find each other without an external LB.
          # leader_tls_servername must match the SAN in the TLS cert (vault_fqdn).
          retry_join {
            leader_api_addr         = "https://vault-0.vault-internal:8200"
            leader_tls_servername   = "${vault_fqdn}"
            leader_client_cert_file = "/vault/tls/tls.crt"
            leader_client_key_file  = "/vault/tls/tls.key"
          }

          retry_join {
            leader_api_addr         = "https://vault-1.vault-internal:8200"
            leader_tls_servername   = "${vault_fqdn}"
            leader_client_cert_file = "/vault/tls/tls.crt"
            leader_client_key_file  = "/vault/tls/tls.key"
          }

          retry_join {
            leader_api_addr         = "https://vault-2.vault-internal:8200"
            leader_tls_servername   = "${vault_fqdn}"
            leader_client_cert_file = "/vault/tls/tls.crt"
            leader_client_key_file  = "/vault/tls/tls.key"
          }
        }

        service_registration "kubernetes" {}

  # Expose Vault via an internet-facing AWS NLB on port 8200
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
