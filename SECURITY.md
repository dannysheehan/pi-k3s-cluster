# Security Policy

This repository contains Ansible playbooks for a personal Raspberry Pi K3s
homelab. It is public for documentation and reuse; treat inventory and network
details as **non-sensitive but not an invitation to scan**.

## Reporting a vulnerability

If you find a security issue in these playbooks or documentation (for example a
secret that should not be public, or a dangerous default):

1. Open a [private security advisory](https://github.com/dannysheehan/pi-k3s-cluster/security/advisories/new) if available, or
2. Email the repository owner via the address on their GitHub profile.

Please do **not** open a public issue for leaked credentials.

## Secrets in this project

- Ansible Vault ciphertext may appear in `group_vars/`; the vault password is
  **not** in the repository (`~/.ansible/vault-pass-pi-cluster` on the operator
  workstation).
- Application secrets for Flux-managed apps are out of band (see
  [docs/GITOPS.md](docs/GITOPS.md)).
- Do not open PRs that add kubeconfigs, tokens, or unvaulted credentials.

## Automated checks

Pull requests and pushes to `main` run YAML lint, ansible-lint, actionlint, and
gitleaks (see `.github/workflows/lint.yml`). GitHub secret scanning and push
protection are enabled on the remote.
