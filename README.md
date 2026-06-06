<div align="center">

# 🛠 useful-scripts

A collection of useful bash scripts for everyday tasks.

![Scripts](https://img.shields.io/badge/scripts-3-blue)
![License](https://img.shields.io/badge/license-MIT-green)

</div>

---

## 📦 Scripts

| Script | Description |
|--------|-------------|
| [kubernetes/install-microk8s.sh](#-install-microk8ssh) | Install and configure MicroK8s on a fresh Ubuntu VPS |
| [kubernetes/spawn-postgres.sh](#-spawn-postgressh) | Spin up a standalone PostgreSQL pod with PVC in a local cluster |
| [kubernetes/telegram-postgres-backup.sh](#-telegram-postgres-backupsh) | Set up daily PostgreSQL backups delivered via Telegram |

---

## ☸ install-microk8s.sh

Installs MicroK8s on a fresh Ubuntu server and configures it for deploying personal services.

<details>
<summary>✅ Requirements</summary>

- Ubuntu 20.04 / 22.04 / 24.04
- Minimum **2 CPU cores** and **2 GB RAM**
- `snap` and `curl` installed
- Ports 80 / 443 free (if public access is needed)

</details>

<details>
<summary>⚙️ How it works</summary>

1. Checks system resources (CPU, RAM)
2. Interactively selects addons to enable
3. Asks whether to expose services on ports 80/443
4. Installs MicroK8s via snap
5. Exports kubeconfig so `kubectl` works out of the box
6. Enables selected addons (`dns` is always enabled)
7. Opens firewall ports via `ufw` if public access was chosen
8. Optionally installs Helm

</details>

**Install:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/isNightmareDream/useful-scripts/main/kubernetes/install-microk8s.sh)
```

---

## 🐘 spawn-postgres.sh

Interactively spins up a standalone PostgreSQL pod with a PVC and a ClusterIP Service in a local Kubernetes cluster. Returns the in-cluster DSN for use by other workloads.

<details>
<summary>✅ Requirements</summary>

- `kubectl` configured and pointing to a local cluster (MicroK8s, minikube, k3d, etc.)
- Default StorageClass available for dynamic PVC provisioning

</details>

<details>
<summary>⚙️ How it works</summary>

1. Interactively asks for pod name, namespace, Postgres version, credentials, database name, and PVC size
2. Creates a `PersistentVolumeClaim` for data persistence
3. Creates a `Pod` running the requested Postgres image
4. Creates a `ClusterIP Service` so other pods can reach Postgres by DNS
5. Waits until the pod is `Ready`
6. Prints the in-cluster DSN

</details>

**Install:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/isNightmareDream/useful-scripts/main/kubernetes/spawn-postgres.sh)
```

**Delete all created resources:**

```bash
kubectl delete pod/<name> svc/<name> pvc/<name>-pvc -n <namespace>
```

---

## 📨 telegram-postgres-backup.sh

Sets up daily PostgreSQL backups from a Kubernetes pod delivered directly to Telegram. Large backups are automatically split into 45 MB parts.

> **Run after Postgres is deployed to the cluster.**

<details>
<summary>✅ Requirements</summary>

- MicroK8s cluster running
- PostgreSQL deployed as a Kubernetes pod
- `kubectl` configured and working
- A Telegram bot token (create via [@BotFather](https://t.me/BotFather))
- Your Telegram `chat_id`

</details>

<details>
<summary>⚙️ How it works</summary>

1. Interactively selects namespace and pod from the cluster
2. Reads database credentials from pod environment variables automatically
3. Verifies the Telegram bot token
4. Creates `/usr/local/bin/postgres-telegram-backup` — runs `pg_dump | zstd -19`
5. If the backup exceeds 45 MB, splits it into parts via `split`
6. Sends each part to Telegram with progress captions
7. Rotates old local backups based on retention days
8. Schedules a daily cron job at **03:00**
9. Optionally runs a test backup immediately

![Telegram backup preview](assets/tg_backup.png)

</details>

**Install:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/isNightmareDream/useful-scripts/main/kubernetes/telegram-postgres-backup.sh)
```

**Uninstall:**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/isNightmareDream/useful-scripts/main/kubernetes/telegram-postgres-backup.sh) --uninstall
```

**Restore from backup:**

```bash
# Decompress
zstd -d quiz-stats_2026-06-06_03-00-01.sql.zst -o backup.sql

# Restore into the pod
kubectl exec -i -n <namespace> <pod> -- psql -U <user> -d <database> < backup.sql
```
