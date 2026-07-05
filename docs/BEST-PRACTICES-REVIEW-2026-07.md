# Pi K3s Cluster: Best-Practices Review & Improvement Plan

Date: 2026-07-05  
Scope: full cluster review based on 216 days of operational history, two
recorded incidents, current configuration in this repo, and current upstream
project state (verified July 2026).

Inputs: `docs/INCIDENT-2026-06-04-GRAFANA-DASHBOARDS.md`,
`docs/INCIDENT-2026-06-30-WRK01-SSD-DISCONNECT.md`, `group_vars/all.yml`,
playbooks 01–04, live cluster state, SMART data from node drives.

---

## What Is Already Good

Credit where due — several practices here are better than most homelab
clusters:

- **Layered, idempotent Ansible** with a documented dependency chain and
  targeted tag reruns.
- **Docs culture**: runbooks, troubleshooting guides, upgrade procedures, and
  honest incident reports with follow-up task lists.
- **Dedicated storage network** for Longhorn replication, isolated from
  application traffic.
- **Heavy-write paths offloaded to SSD** (`/var`, K3s data, Longhorn) to
  protect SD cards.
- **Recent hardening** (post-incident): UUID-based mounts with `nofail`,
  kernel logs shipped off-node, filesystem-error and node-readiness checks in
  `verify-cluster.sh`, SMART monitoring that actually reaches the drives.

The findings below are about the gaps the two incidents exposed and the
structural debt that has accumulated.

---

## Findings

### A. Availability & Detection

#### A1. Single control plane = single point of failure (High)

**Evidence:** One master (`k8s-ctl-01`) running a single-member embedded etcd.
If its SD card, SSD, or PSU fails — the same failure classes both incidents
demonstrated on workers — the entire cluster control plane is gone, and
recovery is a restore-from-snapshot operation.

**Best practice:** 3 control-plane nodes with embedded etcd HA. K3s supports
this natively; masters can also run workloads on small clusters.

**Recommendation:** Move to 3 masters. With 5 Pis that means 3 masters + 2
workers (Longhorn currently has `control_plane_allow_scheduling: false` —
that would need to change, or add a 6th Pi). Addressed in the rebuild plan
(Phase 3).

#### A2. No alerting — a dead node went unnoticed for 4.5 days (High)

**Evidence:** The 2026-06-30 SSD failure was detected on 2026-07-05 by a
human. The 2026-06-04 incident also featured `k3s-wrk-04` sitting NotReady
unnoticed. `verify-cluster.sh` is polling-by-hand; nothing pages.

**Best practice:** An in-cluster alert evaluator (vmalert — native to the
existing VictoriaMetrics stack) plus a notification receiver, with a small
curated rule set: node NotReady, filesystem device errors, Longhorn volume
degraded, vmsingle down, vmagent queue growth, PVC near-full, certificate
expiry.

**Recommendation:** Deploy `vmalert` + Alertmanager (both run fine on Pi;
~50–100 MiB each), notifying via **ntfy** (self-hosted, trivial) or Telegram/
email. Port the existing `verify-cluster.sh` checks into rules — the script
remains useful as an on-demand deep check.

#### A3. No dead-man's switch (Medium)

**Evidence:** All monitoring lives inside the cluster it monitors. A
whole-cluster outage (power, switch, master failure) alerts no one.

**Recommendation:** External heartbeat: a free healthchecks.io check (or ntfy
on a VPS/phone) pinged by a CronJob; missing pings alert from outside. One
Watchdog alert route from Alertmanager to the same target covers
"alerting-is-down".

### B. Storage & Hardware

#### B1. USB-SATA bridges are the weakest link (High)

**Evidence:** The 2026-06-30 incident: bridge dropped off the bus and needed
physical power-cycling. The bridges report spoofed identity (`0930:1400`
"Toshiba Memory Stick 2GB" for a Phison SSD), which is a marker of
bottom-tier enclosure firmware. SMART shows the drives themselves are fine.

**Best practice:** Boot Pis from reliable storage with no bridge in the path,
or at minimum use bridges with honest UAS-tested chipsets (ASMedia ASM1153E,
JMS580 with current firmware).

**Recommendation (tiers):**
1. *Now (free):* keep the `nofail` + UUID + alerting mitigations already done.
2. *Cheap:* replace enclosures with known-good chipsets on the next failure.
3. *Structural (Phase 4):* Pi 5 (or CM5 carrier) with **NVMe HATs** — PCIe
   removes the USB storage path entirely, which eliminates this incident
   class rather than mitigating it.

#### B2. SD-card OS + `/var` bind mount is fragile complexity (Medium)

**Evidence:** The OS boots from SD with `/var` bind-mounted from the SSD.
This split brain is exactly why the 2026-06-30 failure was so messy: logging
died with the SSD, boot safety depended on two coupled fstab entries, and the
SD card still wears (and was implicated in slow logins).

**Best practice:** Pi 4 boots natively from USB. One storage device, no bind
mounts, no SD card at all.

**Recommendation:** On rebuild (Phase 3), image Ubuntu Server directly onto
the SSDs and drop the SD cards and the entire `/var` offload machinery from
`01-infra-prep.yml`. This deletes a whole class of failure modes and ~half of
the infra-prep playbook.

#### B3. Nearly every shutdown is an unsafe shutdown (High)

**Evidence:** SMART on the recovered wrk-01 drive: `Unsafe_Shutdown_Count`
102 of 104 power cycles. The 2026-06-04 VictoriaMetrics `parts.json` NUL-byte
corruption is the textbook signature of exactly this.

**Best practice:** UPS with automated graceful shutdown.

**Recommendation:** A small UPS for the cluster + switch, with **NUT**
(Network UPS Tools): one Pi as NUT server on the UPS USB port, all nodes as
clients doing clean `shutdown` on low battery. Also adopt clean-shutdown
discipline for maintenance (documented drain + shutdown runbook). This is the
single highest data-integrity ROI on the list.

#### B4. Longhorn: 2 replicas, no backup target, aging version (High)

**Evidence:** `longhorn_default_replica_count: 2`, no `backupTarget`
configured, Longhorn 1.7.2 (current: 1.11.x/1.12.x; upgrades must walk each
minor sequentially). The 2026-06-04 corruption had no clean restore path —
recovery was manual quarantine surgery.

**Best practice:** Replicas are not backups. Longhorn's own docs insist on a
backup target (NFS or S3) with scheduled backups via RecurringJobs.

**Recommendation:** 2 replicas is a reasonable capacity/safety trade-off for
5 nodes *once backups exist*. Set up the NAS backup target (C2), add
RecurringJobs (daily backup, hourly snapshot for hot volumes), and **test a
restore**. Version ladder addressed in Phase 3.

#### B5. Storage NIC runs at USB 2.0 speed (Low, verify)

**Evidence:** On wrk-01 the D-Link DUB-1312 gigabit adapter enumerates on the
USB 2.0 bus (480M) — an effective ceiling of ~300 Mbit/s for Longhorn
replication and rebuilds, while the USB 3.0 bus carries only the SSD.

**Recommendation:** Verify on all nodes (`lsusb -t`). If it is port placement,
this may be a deliberate trade-off (isolating SSD bandwidth); if accidental,
moving the NIC to the USB 3 port roughly triples replication/rebuild speed.
Document whichever is chosen.

### C. Data Protection & DR

#### C1. etcd snapshots are local-only (High)

**Evidence:** K3s takes default daily etcd snapshots onto the master's own
disk — the disk whose failure is the scenario snapshots exist for.
`MAINTENANCE.md` documents manual saves only.

**Recommendation:** Configure `etcd-snapshot-schedule-cron` +
`etcd-s3` (or a cron rsync) so snapshots land on the NAS/S3 off-node. Keep
7 daily + 4 weekly. Test the documented restore path once.

#### C2. External NAS as backup + bulk storage tier (High — user goal)

**Recommendation:** Add a NAS (or repurpose any always-on box with disks) and
use it three ways:

| Use | Mechanism |
|---|---|
| Longhorn backup target | NFS export or MinIO (S3) on the NAS |
| etcd snapshot offload | S3 (MinIO) via k3s `etcd-s3` flags |
| Bulk/media/RWX storage class | `nfs-subdir-external-provisioner` — cheap RWX PVCs that don't consume Longhorn replicas |

MinIO on the NAS is preferred over bare NFS for backups: S3 versioning +
easier Velero integration. Longhorn data stays on-node SSDs (fast path);
NAS is capacity + safety tier.

#### C3. No cluster-resource backup (Medium)

**Evidence:** Ansible can rebuild what it deployed, but anything created
imperatively (Grafana dashboards saved in the UI, Longhorn settings, test
namespaces) exists only in etcd.

**Recommendation:** **Velero** with the S3 target (C2), daily schedule.
Pairs with Longhorn CSI snapshots for PV-consistent backups. Alternatively,
strict GitOps (E2) shrinks the problem to "restore Git + PV backups".

### D. Security

#### D1. Secrets hygiene: `grafana_admin_password: "admin"` in Git (High)

**Evidence:** `group_vars/all.yml:45`. Also: K3s secrets-at-rest encryption
is not enabled, and there is no secrets workflow at all — anything sensitive
added later will land in Git the same way.

**Best practice / Recommendation (layered):**
1. Enable K3s `secrets-encryption: true` (config-file flag; on rebuild it is
   free, in-place it requires a documented rotate procedure).
2. Adopt **SOPS + age** for repo secrets (encrypted YAML in Git, decrypted at
   deploy; integrates with both Ansible and Flux). For a 5-node homelab this
   beats running Vault (heavy) — **sealed-secrets** is the alternative if
   GitOps-first.
3. Rotate the Grafana password into that workflow now.

#### D2. Everything is plaintext HTTP (Medium)

**Evidence:** Grafana, Longhorn UI, Traefik dashboard — all `http://` on the
LAN.

**Recommendation:** **cert-manager** with a Let's Encrypt DNS-01 wildcard (if
a real domain is available — free via Cloudflare) or an internal CA; Traefik
already terminates TLS natively. LAN-only is not a strong boundary once any
IoT device shares it.

#### D3. Cilium's policy engine is unused (Low)

**Evidence:** Cilium runs as CNI but no NetworkPolicies exist; every pod can
reach every pod, the NAS, and the Pis' SSH.

**Recommendation:** Start coarse: default-deny egress for `monitoring` and
app namespaces with explicit allows (DNS, vmsingle, vlogs). Hubble (already
deployed) shows the flows to write the policies from. Do this after GitOps so
policies are declarative.

#### D4. Control-plane observability gap (Low)

**Evidence:** Fluent Bit DaemonSet has no control-plane toleration —
`k8s-ctl-01` ships no logs (found during the kernel-log work). The node that
matters most is the least observed.

**Recommendation:** Add `tolerations` for the control-plane taint to the
Fluent Bit (and node-exporter, if affected) chart values.

### E. Lifecycle & Operations

#### E1. Every core component is past end-of-life (High)

Verified July 2026:

| Component | Running | Current | Status |
|---|---|---|---|
| K3s / Kubernetes | v1.31.3 (Nov 2024) | v1.36.x | K8s 1.31 EOL Oct 2025 |
| Cilium | 1.16.4 | 1.19.x (1.17–1.19 supported) | 1.16 EOL |
| Longhorn | 1.7.2 | 1.11.3 / 1.12.0 | Out of support; upgrades cannot skip minors |
| Grafana | 11.1.5 | 12.x | Behind, lower risk |

No security patches are flowing to this cluster. The Longhorn constraint is
the painful one: in-place means walking 1.7→1.8→1.9→1.10→1.11 sequentially,
each with its own pre-upgrade checks — and K3s should move in supported
steps alongside. This materially strengthens the rebuild case (Phase 3).

**Recommendation:** Whichever path is chosen, adopt a cadence afterward:
patch releases monthly, minor versions quarterly, tracked by Renovate (E2).

#### E2. Push-based Ansible for apps; no drift detection (Medium)

**Evidence:** Helm releases are deployed by Ansible from a workstation.
Today's session hit the consequences: Helm repos lived under root from
past `become` runs, user Helm v4 broke the pinned `kubernetes.core`
collection, and `become_ask_pass=True` blocks unattended runs. Imperative
tweaks (kubectl patches in playbooks) drift silently.

**Best practice:** Hosts/OS layer in Ansible; everything above K3s in
**GitOps** (Flux is lighter than Argo CD for Pi clusters, ~150 MiB total).
Renovate PRs version bumps against `group_vars/all.yml` and Flux manifests.

**Recommendation:** On rebuild, bootstrap Flux and move charts (monitoring
stack, Longhorn, Traefik) to HelmReleases; keep playbooks 01–02 for
infra/K3s. Also fix `ansible.cfg`: passwordless sudo exists on nodes, so
`become_ask_pass = True` can go, and pin/upgrade `kubernetes.core` to a
Helm-4-compatible release.

#### E3. Bespoke Multus patch is upgrade-fragile (Medium)

**Evidence:** The Multus DaemonSet needs hand-patched privileges and mount
propagation (documented in CLAUDE.md) — a known trap on every upgrade.

**Recommendation:** Re-evaluate on rebuild whether Multus+Whereabouts is
still required, or whether Longhorn's `storageNetwork` over a simpler
interface config suffices with current Longhorn. If Multus stays, pin the
patch as a strategic-merge file in the repo with a comment block explaining
each field (partially done) and re-test on each `multus_version` bump.

#### E4. Node identity drift (Low)

**Evidence:** `k3s-wrk-03-f118e128`, `k3s-wrk-04-11c34487` (re-add suffixes),
master named `k8s-ctl-01` vs workers `k3s-*`. Cosmetic, but it complicates
automation, dashboards, and matching inventory to cluster.

**Recommendation:** Fix hostnames on rebuild; adopt the documented remove/add
playbooks so re-added nodes keep clean names.

---

## Recommended Additional Components

Curated for Pi-class resources (approximate steady-state memory):

| Component | Purpose | Footprint | Priority |
|---|---|---|---|
| vmalert + Alertmanager | Alert evaluation + routing (A2) | ~120 MiB | **P0** |
| ntfy | Push notifications to phones (A2) | ~20 MiB | **P0** |
| healthchecks.io (external) | Dead-man's switch (A3) | none | **P0** |
| smartctl_exporter | SMART metrics → alert on pre-fail (B1) | ~30 MiB/node | P1 |
| MinIO (on NAS, not cluster) | S3 for Longhorn/etcd/Velero backups (C2) | on NAS | **P1** |
| nfs-subdir-external-provisioner | RWX/bulk StorageClass from NAS (C2) | ~20 MiB | P1 |
| Velero | Cluster + PV backup/restore (C3) | ~150 MiB | P1 |
| SOPS + age (tooling) | Encrypted secrets in Git (D1) | none | **P1** |
| cert-manager | TLS everywhere (D2) | ~100 MiB | P2 |
| Flux | GitOps reconciliation (E2) | ~150 MiB | P2 |
| Renovate (GitHub app) | Automated version-bump PRs (E1) | none | P2 |
| kured | Coordinated reboots for unattended-upgrades | ~20 MiB | P2 |
| NUT (host-level, not k8s) | UPS graceful shutdown (B3) | ~10 MiB/node | **P1** (with UPS) |

Deliberately **not** recommended at this scale: Vault (operationally heavy —
SOPS covers the need), Istio/service mesh (Cilium already provides policy +
observability), Prometheus Operator (VictoriaMetrics stack is the right call
on Pis and is already working), Harbor (use a registry cache only if image
pulls become a problem).

---

## The Plan

Phases are ordered so that every step protects the next one. Phase 1 must
precede Phase 3: **backups before rebuild**.

### Phase 0 — Quick wins (a weekend, no downtime)

1. ~~Deploy vmalert + Alertmanager + ntfy~~ **Done 2026-07-05**: vmalert +
   Alertmanager via `vm/victoria-metrics-alert` chart (`--tags vmalert`),
   kube-state-metrics added, Alertmanager posts straight to ntfy.sh using
   ntfy message templating (no bridge). 12 rules across node-health, storage,
   monitoring-pipeline, and certificates groups; critical alerts push at
   urgent priority. Verified end-to-end.
2. ~~External dead-man's switch~~ **Done 2026-07-05**: two healthchecks.io
   checks — `pi-cluster-heartbeat` (CronJob, 5m) and
   `pi-cluster-alerting-watchdog` (always-firing Watchdog rule routed from
   Alertmanager, ~10m). Ping URLs vaulted. See `docs/ALERTING.md`.
3. Move the Grafana password out of Git (first SOPS-encrypted secret).
4. Fluent Bit + node-exporter control-plane tolerations.
5. `lsusb -t` audit of storage-NIC bus placement (B5); document the outcome.
6. Remove `become_ask_pass` from `ansible.cfg`; fix `kubernetes.core`/Helm 4.

### Phase 1 — Data safety (1–2 weekends, requires NAS hardware)

1. Stand up NAS with MinIO (+ optional NFS export).
2. Longhorn `backupTarget` → MinIO; RecurringJobs (daily backups, retention);
   **restore drill** into a scratch namespace.
3. K3s etcd snapshots: cron schedule + S3 offload; **restore drill** on a
   spare Pi or VM.
4. Velero with daily schedule.
5. UPS + NUT graceful shutdown (kills the unsafe-shutdown pattern behind the
   2026-06-04 corruption).

### Phase 2 — Security & delivery (incremental, low risk)

1. SOPS+age workflow for all repo secrets.
2. cert-manager + TLS for Grafana/Longhorn/Traefik dashboards.
3. Bootstrap Flux; migrate monitoring stack and Longhorn to HelmReleases;
   enable Renovate.
4. First NetworkPolicies (default-deny in `monitoring`, informed by Hubble).

### Phase 3 — Rebuild (recommended over in-place upgrade)

**Why rebuild wins here:** the in-place path is a 4-minor Longhorn ladder ×
sequential K3s hops × EOL Cilium on a single-master cluster with no tested
backups — every step carries risk with no safety net, and at the end the
structural problems (single master, SD boot, `/var` bind, node-name drift)
still exist. A rebuild reaches current versions in one step and fixes the
architecture. Phase 1 makes it safe: workloads restore from Longhorn/Velero
backups.

Blueprint:

1. **Topology:** 3 masters (embedded etcd HA) + 2 workers; allow scheduling
   on masters (adjust Longhorn `control_plane_allow_scheduling` and the
   workload label scheme), or add a 6th Pi to keep 3+3.
2. **Boot:** USB-SSD boot, no SD cards, no `/var` bind (B2). Flash SSDs with
   Ubuntu Server 24.04 + cloud-init (hostname, SSH keys, sysctls) — rework
   `01-infra-prep.yml` down to storage-network + tuning.
3. **K3s:** current stable (1.36.x as of July 2026), config-file based, with
   `secrets-encryption: true`, `etcd-snapshot-schedule-cron` + S3 flags from
   day one. Keep Cilium-as-everything (current 1.19.x), kube-proxy disabled,
   as today.
4. **Storage:** Longhorn current (1.12.x), storage network re-evaluated (E3),
   `backupTarget` configured before the first PVC exists.
5. **Apps via Flux** (from Phase 2), secrets via SOPS. Ansible's job ends at
   "K3s is up".
6. **Migration:** stand up new cluster on 2–3 nodes drained/removed from the
   old one (or on the new Pi 5s from Phase 4), restore PVs from MinIO
   backups, cut DNS/LB over, then absorb the remaining old nodes. Old master
   stays untouched until the new cluster passes a full `verify-cluster.sh`
   equivalent + restore drill. Rollback = repoint DNS/LB back.
7. **Naming/inventory:** clean hostnames (`pi-ctl-0{1..3}`, `pi-wrk-0{1..n}`),
   `hosts.ini` regenerated, per-node vars for storage MACs as today.

### Phase 4 — Hardware evolution (opportunistic)

- Pi 5 / CM5 + NVMe HATs for new or replacement nodes — removes the
  USB-SATA bridge failure class permanently (B1).
- Known-good enclosure chipsets for any Pi 4s that remain.
- PoE+ HATs + PoE switch if cable sprawl/power bricks are a pain point
  (single point of power control also simplifies UPS sizing).

---

## Decision Points

1. **Rebuild vs in-place ladder** — this document recommends rebuild
   (Phase 3 rationale). In-place is viable if downtime tolerance is zero,
   but budget 5× the effort spread over weeks.
2. **3+2 vs 3+3 topology** — schedule workloads on masters, or buy a 6th Pi.
3. **NAS choice** — dedicated NAS appliance vs any x86 box with disks vs a
   pair of large drives on one Pi 5 (last option is weakest: shares the
   failure domain being protected against).
4. **Notification channel** — ntfy (self-hosted) vs Telegram/email (zero
   hosting).
5. **Domain for TLS** — real domain + DNS-01 wildcard vs internal CA (real
   domain is less friction long-term).

---

## Sources

- [k3s releases](https://github.com/k3s-io/k3s/releases) /
  [k3s v1.36 release notes](https://docs.k3s.io/release-notes/v1.36.X) —
  v1.36.2+k3s1 current (2026-06-24)
- [Longhorn releases](https://github.com/longhorn/longhorn/releases) /
  [longhorn.io](https://longhorn.io/) — v1.12.0 (2026-06-02), v1.11.3
  (2026-07-02); sequential-minor upgrade requirement
- [Cilium releases](https://github.com/cilium/cilium/releases) /
  [endoflife.date/cilium](https://endoflife.date/cilium) — v1.19.5 current;
  1.17–1.19 maintained
- Longhorn backup/restore, K3s HA embedded etcd, and K3s secrets-encryption
  per upstream docs ([longhorn.io/docs](https://longhorn.io/docs/),
  [docs.k3s.io](https://docs.k3s.io/))
