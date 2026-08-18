# full_custom_gitlab_setup

Self-hosted GitLab CE on a single Docker host, with a full backup → restore lifecycle designed for disaster recovery onto a **completely blank VM**.

This repo covers three things:
1. First-time setup of GitLab CE via Docker Compose
2. Scheduled/manual backups (native GitLab backup + config + SSH host keys)
3. One-command ground-up restore onto a fresh machine — including Docker install, correct GitLab version detection, and `external_url` reconciliation

---

## 1. First-time setup

Run these on a fresh VM, in order.

```bash
sudo bash scripts/first_time_setup/setup1.sh
# installs docker.io + docker-compose-v2, enables docker, adds current user
# to the docker group, then reboots the machine
```

After reboot:

```bash
bash scripts/first_time_setup/setup2.sh
# pulls gitlab/gitlab-ce:latest, creates /code/gitlab/{config,logs,data},
# and runs `docker compose up -d`
```

Before running `setup2.sh`, edit `docker-compose.yaml` and replace the placeholders:

| Placeholder | Description |
|---|---|
| `<hostname>` | Container hostname, e.g. `gitlab.example.com` |
| `<external_url>` | Public URL GitLab will be reachable at, e.g. `http://gitlab.example.com:8080` |

Default port mapping: **HTTP `8080:80`**, **SSH `6022:22`**. Data, config, and logs are bind-mounted from `/code/gitlab/{data,config,logs}` on the host.

Once running, retrieve the initial root password:

```bash
docker exec -it gitlab cat /etc/gitlab/initial_root_password
```

---

## 2. Backups

`scripts/backup-script.sh` produces a single portable archive containing everything needed to fully reconstruct the instance:

- GitLab's native backup (`gitlab-backup create`)
- `/code/gitlab/config` (includes `gitlab.rb`, `gitlab-secrets.json`, and SSH host keys — GitLab embeds these in config unless split out separately)
- A separate `/code/gitlab/ssh` directory, if present

```bash
sudo bash scripts/backup-script.sh
```

Output: `/gitlabs/gitlab-backup/gitlab-complete-<timestamp>.tar.gz`

### Optional: offsite upload to Azure Blob Storage

Local backups on the same host they're protecting aren't real disaster recovery — if the VM or disk is lost, the backup goes with it. The script includes a commented-out upload step (via `az storage blob upload` + SAS token) at the bottom to send each archive to Azure Blob Storage after it's created.

To enable it:

1. **Uncomment** the block at the bottom of `scripts/backup-script.sh` (the `# echo "==> 7. Uploading..."` section onward).
2. **Store the SAS token** in a root-only config file at `/etc/gitlab-backup/azure-sas-token.conf`:
   ```bash
   sudo mkdir -p /etc/gitlab-backup
   sudo tee /etc/gitlab-backup/azure-sas-token.conf > /dev/null <<'EOF'
   SAS_TOKEN="sv=...&sig=..."
   EOF
   sudo chmod 600 /etc/gitlab-backup/azure-sas-token.conf
   ```
   The script sources this file at runtime (`source /etc/gitlab-backup/azure-sas-token.conf`) rather than hardcoding the token in the script itself. Keep this file **out of the repo** and restrict it to `600` root-only — the token grants write access to the backup container.
3. **Fill in `<storage_account_name>`** in the script with your actual Azure Storage account name, and confirm the container name (`gitlabbackups` by default) already exists.
4. Scope the SAS token to only what's needed — write/create permissions on the single `gitlabbackups` container, with a sensible expiry (not a decade out), rather than full account access.

**Scheduling:** this repo schedules the wrapper via **systemd** — see below.

---

## Repo layout

```
.
├── docker-compose.yaml               # Base compose file for a fresh install
├── auto_restore.sh                   # One-shot disaster-recovery restore script
└── scripts/
    ├── backup-script.sh              # Creates a full backup archive
    ├── backup_wrapper/
    │   └── backup_wrapper.sh         # Runs backup, prunes old local copies
    ├── systemd/
    │   ├── gitlab-backup.service     # Runs backup_wrapper.sh once
    │   └── gitlab-backup.timer       # Fires the service every 3 days
    └── first_time_setup/
        ├── setup1.sh                 # Installs Docker, adds user to docker group, reboots
        └── setup2.sh                 # Pulls the image, creates dirs, brings up GitLab
```

---

## Automated scheduling — `backup_wrapper.sh`

`scripts/backup_wrapper/backup_wrapper.sh` wraps `backup-script.sh` for unattended, scheduled runs. It handles two things `backup-script.sh` doesn't:

1. **Runs the backup** (which creates the local `.tar.gz` and, if enabled, uploads it to Azure Blob Storage).
2. **Prunes old local backups** — but only after confirming the new backup actually succeeded and isn't empty/truncated. Keeps just the newest local archive; **Azure Blob is never touched by this script** — old blobs there are retained regardless of local cleanup.

This repo schedules it with **systemd** (see below) rather than cron, for dependency ordering on Docker/network, automatic catch-up on missed runs, and better logging via `journalctl`.

### Safety checks before deleting anything

- Backup script must exit `0`, or nothing is deleted.
- The newest `gitlab-complete-*.tar.gz` must actually exist after the run.
- The newest archive must be at least 1 MB — guards against silently keeping/rotating a truncated or empty backup.

If any of these fail, **all existing local backups are left untouched** and the run exits non-zero with a logged reason.

### Setup

```bash
# Place the backup script where the wrapper expects it
mkdir -p /gitlabs/backups-gitlab
cp scripts/backup-script.sh /gitlabs/backups-gitlab/backup-script.sh
chmod +x /gitlabs/backups-gitlab/backup-script.sh

# Install the wrapper somewhere on PATH so systemd can call it directly
cp scripts/backup_wrapper/backup_wrapper.sh /usr/local/bin/backup_wrapper.sh
chmod +x /usr/local/bin/backup_wrapper.sh
```

### Install the systemd timer

```bash
cp scripts/systemd/gitlab-backup.service /etc/systemd/system/gitlab-backup.service
cp scripts/systemd/gitlab-backup.timer   /etc/systemd/system/gitlab-backup.timer
systemctl daemon-reload
systemctl enable --now gitlab-backup.timer
```

- `gitlab-backup.timer` fires 10 minutes after boot, then every 3 days thereafter (`OnUnitActiveSec=3d`), and `Persistent=true` means a missed run (e.g. VM was off) fires as soon as the system is back up.
- `gitlab-backup.service` runs `/usr/local/bin/backup_wrapper.sh` as a `oneshot`, ordered after `docker.service` and `network-online.target` (needed for the Docker backup exec and the Azure upload step), with a 3-hour timeout headroom for large instances.

Check it:

```bash
systemctl list-timers gitlab-backup.timer
systemctl status gitlab-backup.service
journalctl -u gitlab-backup.service -f
```

Trigger a run manually without waiting for the timer:

```bash
systemctl start gitlab-backup.service
```

Logs are also written to `/var/log/gitlab-backup.log` (created/appended automatically) — this is in addition to `journalctl`, not a replacement for it.

### Config

| Variable | Default | Purpose |
|---|---|---|
| `BACKUP_SCRIPT` | `/gitlabs/backups-gitlab/backup-script.sh` | Path to the underlying backup script |
| `BACKUP_DIR` | `/gitlabs/gitlab-backup` | Where local backup archives live |
| `LOG_FILE` | `/var/log/gitlab-backup.log` | Run log |

Update these paths at the top of the script if your layout differs from the defaults above.

---
---

## 3. Disaster recovery — `auto_restore.sh`

This is the core of the repo: a **single command** that takes a blank VM and a backup archive, and produces a fully working GitLab instance — no manual Docker install, no manual version matching, no manual `external_url` fixups.

### Usage

```bash
# Place auto_restore.sh in the SAME folder as the backup archive
# (gitlab-complete-<timestamp>.tar.gz), then:
sudo bash auto_restore.sh
```

Optional environment overrides:

```bash
GITLAB_HOSTNAME=git.example.com HTTP_PORT=8080 SSH_PORT=6022 sudo bash auto_restore.sh
```

### What it does, step by step

1. **Locate the backup** — looks for exactly one `gitlab-complete-*.tar.gz` next to the script; aborts if zero or multiple are found.
2. **Detect public IP** — tries AWS IMDSv2 → IMDSv1 → Azure IMDS → `checkip.amazonaws.com` → `api.ipify.org`, in that order, falling back to a manual prompt if all fail. This becomes the `external_url`.
3. **Read the GitLab version from the archive** — parses `backup_information.yml` inside the native backup tar to pin the exact image tag (`gitlab/gitlab-ce:<version>-ce.0`), so the restored instance matches the version it was backed up from. Falls back to a manual prompt if the version can't be parsed.
4. **Disk space pre-flight check** — requires ~4x the archive size free before proceeding.
5. **Create directory structure from scratch** — `/code/gitlab/{config,logs,data}` and `/gitlabs`.
6. **Generate a version-pinned `docker-compose.yaml`** at `/gitlabs/docker-compose.yaml`.
7. **Bring up a fresh container**, wait for GitLab to become responsive (`gitlab-rake gitlab:env:info`), then check the running version against the archive's expected version. This check is **informational only** — a mismatch logs a warning but does not fail the run, since the container image was already pinned correctly in step 6 and version-string formatting differs between `backup_information.yml` and `version-manifest.txt`.
8. **Restore config, SSH keys, and data** — stops the container, moves any freshly-created directories aside as `*.pre-restore.<timestamp>` (rollback safety net), extracts the archive, restores config with `root:root` ownership, and runs `gitlab-backup restore`.
9. **Patch `external_url`** — `gitlab-backup restore` brings back the *original* server's `gitlab.rb`, which still points at the old production URL. `GITLAB_OMNIBUS_CONFIG` only applies on a container's first-ever boot with an empty `/etc/gitlab`, so it's silently ignored at this point. The script instead `sed`-patches `external_url` directly into the restored `gitlab.rb`, then reconfigures.
10. **Reconfigure and restart** all GitLab services.

### Safety features

- **Confirmation prompt** before doing anything destructive (`Type 'yes' to continue`).
- **Automatic rollback on failure** (`trap rollback ERR`): stops the container, restores the pre-restore directory snapshots, and attempts to bring the container back up. If the container was freshly created this run, it's left stopped rather than guessing a safe restart state.
- **Pre-restore snapshots** of `config`, `logs`, `data`, and `ssh` are kept on disk after a successful restore (`*.pre-restore.<timestamp>`) — delete manually once verified.

### After a successful restore

```
Restore complete. GitLab <version> is running from scratch.
  URL:    http://<detected-ip>:8080
  SSH:    port 6022
  Status: docker exec gitlab gitlab-ctl status
  Logs:   docker logs -f gitlab
```

Once real DNS points at the VM, update `external_url` in `/etc/gitlab/gitlab.rb` (or `/code/gitlab/config/gitlab.rb` on the host) and run:

```bash
docker exec gitlab gitlab-ctl reconfigure
```

---

## Defaults reference

| Setting | Default | Override |
|---|---|---|
| Hostname | `git.example.local` | `GITLAB_HOSTNAME` |
| HTTP port | `8080` | `HTTP_PORT` |
| SSH port | `6022` | `SSH_PORT` |
| GitLab root (host) | `/code/gitlab` | hardcoded in `auto_restore.sh` |
| Compose dir | `/gitlabs` | hardcoded in `auto_restore.sh` |
| Backup destination | `/gitlabs/gitlab-backup` | hardcoded in `backup-script.sh` |

## Requirements

- A Linux VM (tested against Ubuntu/apt-based hosts — `setup1.sh` and `auto_restore.sh` both call `apt-get`)
- Root/sudo access
- Outbound internet access to pull `gitlab/gitlab-ce` images from Docker Hub
- Enough free disk for GitLab data + roughly 4x the backup archive size during restore

## Known limitations

- `auto_restore.sh` assumes an apt-based distro for Docker installation.
- Restore currently expects exactly one backup archive in the script's directory.
- Cloud metadata IP detection is tuned for AWS and Azure; other clouds fall through to the public IP-echo services.
- No TLS termination in `docker-compose.yaml` — this repo assumes GitLab sits behind a reverse proxy, load balancer, or is otherwise only reachable over a private network/VPN. If exposing it directly to the internet, put TLS in front of it.
- Scheduling is systemd-only in this repo — there's no cron fallback included. If your VM doesn't run systemd, you'll need to adapt `gitlab-backup.service`'s `ExecStart` into a cron entry yourself.
- Offsite (Azure Blob) upload is opt-in and off by default in `backup-script.sh`; without enabling it, backups live only on the same host they're protecting.
- The backup wrapper prunes old **local** archives only — it has no retention policy for Azure Blob Storage itself; set lifecycle rules on the container in Azure if you want old blobs cleaned up automatically.