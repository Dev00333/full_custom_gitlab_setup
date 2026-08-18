#!/bin/bash
#
# backup_wrapper.sh
#
# Runs the existing GitLab backup script (which creates the tar.gz AND
# uploads it to Azure Blob Storage), and — only if that succeeds — deletes
# all older local backups in BACKUP_DIR, keeping just the newest one.
#
# Azure Blob Storage is never touched by this script; old blobs stay there
# regardless of what happens locally.
#
# Scheduled via systemd (gitlab-backup.timer -> gitlab-backup.service),
# every 3 days.

set -euo pipefail

# ---- Config ----
BACKUP_SCRIPT="/gitlabs/backups-gitlab/backup-script.sh"
BACKUP_DIR="/gitlabs/gitlab-backup"
LOG_FILE="/var/log/gitlab-backup.log"

log() {
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') $*" | tee -a "$LOG_FILE"
}

log "=== Starting scheduled GitLab backup ==="

if [ ! -x "$BACKUP_SCRIPT" ]; then
  log "ERROR: Backup script not found or not executable: $BACKUP_SCRIPT"
  exit 1
fi

# ---- Snapshot existing backups BEFORE running, so we know what's "old" ----
mapfile -t BEFORE < <(find "$BACKUP_DIR" -maxdepth 1 -name "gitlab-complete-*.tar.gz" 2>/dev/null | sort)
log "Existing backups before this run: ${#BEFORE[@]}"

# ---- Run the actual backup script ----
log "Running $BACKUP_SCRIPT ..."
if ! "$BACKUP_SCRIPT" >>"$LOG_FILE" 2>&1; then
  log "ERROR: Backup script failed. Leaving all existing local backups untouched."
  exit 1
fi
log "Backup script completed successfully."

# ---- Identify the newest backup (the one just created) ----
NEWEST=$(find "$BACKUP_DIR" -maxdepth 1 -name "gitlab-complete-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -n1 | cut -d' ' -f2-)

if [ -z "$NEWEST" ]; then
  log "ERROR: Backup script reported success but no gitlab-complete-*.tar.gz found in $BACKUP_DIR."
  log "Not deleting anything — refusing to guess at cleanup with no confirmed new backup."
  exit 1
fi

# Sanity check the new backup isn't empty/truncated before trusting it
NEWEST_SIZE=$(stat -c%s "$NEWEST")
if [ "$NEWEST_SIZE" -lt 1000000 ]; then
  log "ERROR: Newest backup ($NEWEST) is suspiciously small (${NEWEST_SIZE} bytes)."
  log "Not deleting old backups — keeping them as a safety net until this is investigated."
  exit 1
fi

log "Confirmed new backup: $NEWEST (${NEWEST_SIZE} bytes)"

# ---- Delete every other local backup, keep only the newest ----
DELETED_COUNT=0
while IFS= read -r -d '' old_file; do
  if [ "$old_file" != "$NEWEST" ]; then
    log "Deleting old local backup: $old_file"
    rm -f "$old_file"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  fi
done < <(find "$BACKUP_DIR" -maxdepth 1 -name "gitlab-complete-*.tar.gz" -print0 2>/dev/null)

log "Deleted $DELETED_COUNT old local backup(s). Kept: $NEWEST"
log "=== Backup cycle complete ==="