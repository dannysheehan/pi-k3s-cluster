# Helper Scripts

These scripts are lightweight operator helpers for common checks and should stay
safe to run repeatedly.

## `verify-cluster.sh`

Runs a quick day-2 verification pass against the cluster using
`~/.kube/config-rpi` by default.

Usage:

```bash
chmod +x scripts/verify-cluster.sh
./scripts/verify-cluster.sh
```

To use a different kubeconfig:

```bash
KUBECONFIG=/path/to/config ./scripts/verify-cluster.sh
```
