# Secrets management with 1Password

The cluster uses External Secrets Operator (ESO) with its 1Password SDK
provider. The SDK talks directly to 1Password, so no in-cluster 1Password
Connect server is required. The older ESO Connect provider is deprecated; the
SDK provider is the preferred direction but is still classified as alpha by
ESO, so upgrades and secret rotation require a tested rollback.

Ansible owns the ESO Helm release and the `onepassword` ClusterSecretStore.
Flux may own namespaced `ExternalSecret` resources after the off-cluster Git
remote is ready. Neither Git nor Flux owns the bootstrap token.

## 1Password preparation

1. Create a dedicated vault for this cluster. Do not grant the integration
   access to personal or unrelated vaults.
2. Create a dedicated 1Password service account with read-only access to that
   vault. Record its token in 1Password or another offline recovery record;
   the token is normally shown only once.
3. Set the non-secret vault identifier as `onepassword_vault_id` in
   `group_vars/all.yml`.
4. Ensure item field labels are unique. The SDK provider rejects ambiguous
   duplicate labels.

Follow the official [1Password SDK provider documentation](https://external-secrets.io/latest/provider/1password-sdk/)
for the current item and field reference syntax.

## Bootstrap

Run the playbook from a trusted terminal after the Kubernetes baseline is
healthy:

```bash
uv run ansible-playbook 05-secrets.yml
```

On the first run, paste the 1Password service-account token into the private
prompt. This is the long value beginning with `ops_`, not the 26-character
vault ID. The playbook rejects an invalid token format before installing or
waiting on any resources. Ansible writes it directly to the `onepassword-service-account`
Kubernetes Secret with `no_log`; the value is not written to this repository.
On later runs, leave the prompt blank to retain the existing Secret. Entering
a value deliberately rotates it.

This token is the unavoidable bootstrap secret. K3s secrets encryption at
rest is enabled, but that is not a backup. Keep an offline recovery copy and
document token revocation. If the cluster is rebuilt, supply the token again
before ExternalSecrets can reconcile.

## Define a consumer

Store an item such as `grafana-admin` in the dedicated vault with unique
`username` and `password` fields. A namespaced consumer can then request a
normal Kubernetes Secret without committing its values:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-admin
  namespace: monitoring
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: grafana-admin
    creationPolicy: Owner
  data:
    - secretKey: admin-user
      remoteRef:
        key: grafana-admin/username
    - secretKey: admin-password
      remoteRef:
        key: grafana-admin/password
```

Adopt existing secrets one at a time. First create and validate the 1Password
item, apply the ExternalSecret, confirm its Ready condition and target keys,
then restart only the consumer that needs the new value. Do not bulk-migrate
the vaulted monitoring credentials during the clean baseline deployment.

## Verify and recover

```bash
kubectl get pods -n external-secrets
kubectl get clustersecretstore onepassword
kubectl get externalsecrets -A
kubectl describe externalsecret -n <namespace> <name>
```

The permanent `external-secrets/onepassword-canary` ExternalSecret is managed
by Flux from `home-gitops`. It reads a randomly generated, non-production
`external-secrets-canary/password` item and proves the full provider path. Its
target Secret must contain only the `value` key; routine checks never reveal it.

Never print or decode target Secrets during routine verification. If the store
is not Ready, check controller events, outbound DNS/HTTPS access to 1Password,
the vault identifier, service-account scope, and whether the token was revoked.
If 1Password is temporarily unavailable, existing Kubernetes Secrets remain;
new values and rotations do not reconcile until access returns.
