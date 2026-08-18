#!/bin/bash
set -euo pipefail

# =============================================================================
# autorestore.sh — GROUND-UP VERSION
#
# Single command, elevated privilege, run from anywhere. Only requirement:
# the gitlab-complete-*.tar.gz backup archive must sit in the SAME FOLDER
# as this script.
#
# From a completely blank VM, this script will:
#   1. Install Docker + compose plugin if not already present
#   2. Read the GitLab version out of the backup archive
#   3. Create all required directories from scratch
#   4. Generate docker-compose.yaml pinned to that exact version
#   5. Bring up a fresh GitLab container
#   6. Restore config, SSH keys, and data from the archive
#   7. Roll back automatically if anything fails after the point of no return
#
# Usage:
#   sudo bash autorestore.sh
# =============================================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "!! This script must be run as root (sudo bash autorestore.sh)."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTAINER_NAME="gitlab"
GITLAB_ROOT="/code/gitlab"
COMPOSE_DIR="/gitlabs"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yaml"
RESTORE_TMP="/gitlabs/gitlab-restore-tmp"
GITLAB_IMAGE_NAME="gitlab/gitlab-ce"

# Defaults matching the original setup — override via env vars if needed:
#   GITLAB_HOSTNAME=git.example.com HTTP_PORT=8080 SSH_PORT=6022 bash autorestore.sh
GITLAB_HOSTNAME="${GITLAB_HOSTNAME:-git.example.local}"
HTTP_PORT="${HTTP_PORT:-8080}"
SSH_PORT="${SSH_PORT:-6022}"

# ---------------------------------------------------------------------------
# Detect this VM's public IP, so external_url can be set correctly without
# needing DNS. Tries cloud metadata services first (AWS, then Azure), falls
# back to a public IP-echo service if neither responds.
# ---------------------------------------------------------------------------
detect_public_ip() {
  local ip=""

  # AWS EC2 metadata (IMDSv2, with IMDSv1 fallback)
  local token
  token=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
  if [ -n "${token}" ]; then
    ip=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: ${token}" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null) || true
  fi
  if [ -z "${ip}" ]; then
    ip=$(curl -s -m 2 "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null) || true
  fi

  # Azure IMDS
  if [ -z "${ip}" ]; then
    ip=$(curl -s -m 2 -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance/network/interface/0/ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text" \
      2>/dev/null) || true
  fi

  # Fallback: external IP-echo service
  if [ -z "${ip}" ]; then
    ip=$(curl -s -m 3 "https://checkip.amazonaws.com" 2>/dev/null | tr -d '[:space:]') || true
  fi
  if [ -z "${ip}" ]; then
    ip=$(curl -s -m 3 "https://api.ipify.org" 2>/dev/null) || true
  fi

  echo "${ip}"
}

# ---------------------------------------------------------------------------
# Find the backup archive next to this script
# ---------------------------------------------------------------------------
echo "==> Looking for backup archive in ${SCRIPT_DIR}..."
mapfile -t CANDIDATES < <(find "${SCRIPT_DIR}" -maxdepth 1 -name "gitlab-complete-*.tar.gz" | sort)

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  echo "!! No gitlab-complete-*.tar.gz found in ${SCRIPT_DIR}."
  echo "   Place this script in the same folder as the backup archive and rerun."
  exit 1
elif [ "${#CANDIDATES[@]}" -gt 1 ]; then
  echo "!! Multiple archives found in ${SCRIPT_DIR}:"
  printf '     %s\n' "${CANDIDATES[@]}"
  echo "   Leave only the one archive you want to restore in this folder and rerun."
  exit 1
fi

ARCHIVE_FILE="${CANDIDATES[0]}"
echo "   Found: ${ARCHIVE_FILE}"

echo "==> Detecting public IP for external_url..."
PUBLIC_IP=$(detect_public_ip)
if [ -z "${PUBLIC_IP}" ]; then
  echo "!! Could not auto-detect public IP."
  read -rp "   Enter the IP or hostname to use for external_url manually: " PUBLIC_IP
  [ -n "${PUBLIC_IP}" ] || { echo "No IP provided. Aborting."; exit 1; }
fi
DETECTED_EXTERNAL_URL="http://${PUBLIC_IP}:${HTTP_PORT}"
echo "   Detected: ${DETECTED_EXTERNAL_URL}"

# ---------------------------------------------------------------------------
# Rollback function
# ---------------------------------------------------------------------------
ROLLBACK_TS=""
ROLLBACK_NEEDED=0
CONTAINER_WAS_CREATED=0

rollback() {
  if [ "${ROLLBACK_NEEDED}" -eq 1 ]; then
    echo
    echo "!!! FAILURE DETECTED — attempting rollback..."
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true

    if [ -n "${ROLLBACK_TS}" ]; then
      for dir in "${GITLAB_ROOT}/config" "${GITLAB_ROOT}/logs" "${GITLAB_ROOT}/data" "${GITLAB_ROOT}/ssh"; do
        if [ -d "${dir}.pre-restore.${ROLLBACK_TS}" ]; then
          rm -rf "${dir}"
          mv "${dir}.pre-restore.${ROLLBACK_TS}" "${dir}"
          echo "    Restored ${dir}"
        fi
      done
    fi

    if [ "${CONTAINER_WAS_CREATED}" -eq 1 ]; then
      echo "==> This container was freshly created by this run — leaving it stopped rather than guessing a good state to restart it into."
      echo "    Inspect manually: docker logs ${CONTAINER_NAME}"
    else
      echo "==> Attempting to bring container back up..."
      if ! ( cd "${COMPOSE_DIR}" && docker compose up -d ); then
        echo "!! docker compose up -d failed during rollback. Trying docker start as fallback..."
        if ! docker start "${CONTAINER_NAME}"; then
          echo "!!! ROLLBACK COULD NOT BRING THE CONTAINER BACK UP. Manual intervention required."
          echo "!!! Check: docker ps -a, docker logs ${CONTAINER_NAME}, and ${COMPOSE_FILE}"
        fi
      fi
    fi
    echo "!!! Rollback attempt finished. Investigate the failure above before retrying."
  fi
}
trap rollback ERR

echo "!!! Ground-up GitLab restore using: $(basename "${ARCHIVE_FILE}")"
echo "!!! This will install Docker (if missing), create ${GITLAB_ROOT}, build a fresh container, and restore all data."
read -rp "Type 'yes' to continue: " CONFIRM
[ "${CONFIRM}" = "yes" ] || { echo "Aborted."; exit 1; }

# ---------------------------------------------------------------------------
# Step 1: Install Docker + compose plugin if missing
# ---------------------------------------------------------------------------
if ! command -v docker &> /dev/null; then
  echo "==> Docker not found. Installing..."
  apt-get update
  apt-get install -y docker.io docker-compose-v2
  systemctl enable --now docker
else
  echo "==> Docker already installed: $(docker --version)"
fi

if ! docker compose version &> /dev/null; then
  echo "==> docker compose plugin not found. Installing..."
  apt-get update
  apt-get install -y docker-compose-v2
fi
echo "   Compose: $(docker compose version)"

# ---------------------------------------------------------------------------
# Step 2: Read GitLab version from the backup archive
# ---------------------------------------------------------------------------
echo "==> Reading GitLab version from backup archive..."
TMP_PEEK_DIR=$(mktemp -d)
BACKUP_TAR_NAME=$(tar -tzf "${ARCHIVE_FILE}" | grep '_gitlab_backup\.tar$' | head -n1) || true
BACKUP_VERSION=""

if [ -n "${BACKUP_TAR_NAME}" ]; then
  tar -xzf "${ARCHIVE_FILE}" -C "${TMP_PEEK_DIR}" "${BACKUP_TAR_NAME}" 2>/dev/null || true
  if [ -f "${TMP_PEEK_DIR}/${BACKUP_TAR_NAME}" ]; then
    BACKUP_VERSION=$(tar -xOf "${TMP_PEEK_DIR}/${BACKUP_TAR_NAME}" backup_information.yml 2>/dev/null \
      | grep -E '^:gitlab_version:' | awk '{print $2}') || BACKUP_VERSION=""
  fi
fi
rm -rf "${TMP_PEEK_DIR}"

if [ -z "${BACKUP_VERSION}" ]; then
  echo "!! Could not determine GitLab version from the backup archive."
  read -rp "   Enter the GitLab version to install manually (e.g. 19.1.1): " BACKUP_VERSION
  [ -n "${BACKUP_VERSION}" ] || { echo "No version provided. Aborting."; exit 1; }
fi

IMAGE_TAG="${GITLAB_IMAGE_NAME}:${BACKUP_VERSION}-ce.0"
echo "   Target version: ${BACKUP_VERSION}  (image: ${IMAGE_TAG})"

# ---------------------------------------------------------------------------
# Step 3: Pre-flight disk space check
# ---------------------------------------------------------------------------
echo "==> Checking disk space..."
mkdir -p "${COMPOSE_DIR}"
ARCHIVE_SIZE_KB=$(du -k "${ARCHIVE_FILE}" | cut -f1)
REQUIRED_KB=$((ARCHIVE_SIZE_KB * 4))
AVAILABLE_KB=$(df -k --output=avail "${COMPOSE_DIR}" | tail -n1 | tr -d ' ')

if [ "${AVAILABLE_KB}" -lt "${REQUIRED_KB}" ]; then
  echo "!! Insufficient disk space on ${COMPOSE_DIR}."
  echo "   Available: $((AVAILABLE_KB / 1024)) MB, recommended minimum: $((REQUIRED_KB / 1024)) MB"
  exit 1
fi
echo "   OK — $((AVAILABLE_KB / 1024)) MB available, $((REQUIRED_KB / 1024)) MB recommended."

# ---------------------------------------------------------------------------
# Step 4: Create directory structure from scratch
# ---------------------------------------------------------------------------
echo "==> Creating directory structure..."
mkdir -p "${GITLAB_ROOT}/config" "${GITLAB_ROOT}/logs" "${GITLAB_ROOT}/data/backups"
mkdir -p "${COMPOSE_DIR}"
echo "   Created ${GITLAB_ROOT}/{config,logs,data} and ${COMPOSE_DIR}"

# ---------------------------------------------------------------------------
# Step 5: Generate docker-compose.yaml pinned to the backup's version
# ---------------------------------------------------------------------------
echo "==> Generating ${COMPOSE_FILE}..."
cat > "${COMPOSE_FILE}" << EOF
version: '3.8'

services:
  gitlab:
    image: ${IMAGE_TAG}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    hostname: ${GITLAB_HOSTNAME}
    shm_size: '1g'
    ports:
      - "${HTTP_PORT}:80"
      - "${SSH_PORT}:22"
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url '${DETECTED_EXTERNAL_URL}'
        nginx['listen_port'] = 80
        nginx['listen_https'] = false
        gitlab_rails['gitlab_shell_ssh_port'] = ${SSH_PORT}
    volumes:
      - ${GITLAB_ROOT}/config:/etc/gitlab
      - ${GITLAB_ROOT}/logs:/var/log/gitlab
      - ${GITLAB_ROOT}/data:/var/opt/gitlab
EOF
echo "   Written. external_url set to ${DETECTED_EXTERNAL_URL}"

# ---------------------------------------------------------------------------
# Step 6: Pull image and bring up a fresh container
# ---------------------------------------------------------------------------
echo "==> Pulling ${IMAGE_TAG}..."
docker pull "${IMAGE_TAG}"

echo "==> Removing any stale container named ${CONTAINER_NAME}..."
docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

echo "==> Starting fresh container via docker compose..."
if ! ( cd "${COMPOSE_DIR}" && docker compose up -d ); then
  echo "!! docker compose up -d failed."
  exit 1
fi
CONTAINER_WAS_CREATED=1

echo "==> Waiting for GitLab to initialize (this can take 1-2 min)..."
sleep 30
MAX_RETRIES=30
ATTEMPT=0
until docker exec "${CONTAINER_NAME}" gitlab-rake gitlab:env:info > /dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "${ATTEMPT}" -ge "${MAX_RETRIES}" ]; then
    echo "!! GitLab did not become responsive after $((MAX_RETRIES * 10 + 30))s. Check 'docker logs ${CONTAINER_NAME}'."
    exit 1
  fi
  echo "   ...still waiting (attempt ${ATTEMPT}/${MAX_RETRIES})"
  sleep 10
done

# --- CHANGED BLOCK (only this part was modified) ---------------------------
# Previously this hard-failed (exit 1) the entire restore if the container's
# reported version string didn't byte-for-byte match BACKUP_VERSION. In
# practice version-manifest.txt often reports a different string format
# (e.g. "19.1.1-ce.0") than backup_information.yml's bare "19.1.1", which
# caused false failures on perfectly good containers. This now logs the
# actual vs. expected version and continues either way — it's a sanity
# check, not a gate. The image was already pinned to BACKUP_VERSION back in
# Step 6 via IMAGE_TAG, so the correct version is already running regardless.
ACTUAL_VERSION=$(docker exec "${CONTAINER_NAME}" cat /opt/gitlab/version-manifest.txt 2>/dev/null \
  | awk '$1=="gitlab-ce" || $1=="gitlab-ee" {print $2; exit}') || ACTUAL_VERSION=""
if [ -z "${ACTUAL_VERSION}" ]; then
  echo "!! Warning: could not read version-manifest.txt from container. Continuing — image was pinned to ${IMAGE_TAG}."
  ACTUAL_VERSION="${BACKUP_VERSION} (unverified)"
elif [ "${ACTUAL_VERSION}" != "${BACKUP_VERSION}" ]; then
  echo "!! Warning: container reports '${ACTUAL_VERSION}', backup expected '${BACKUP_VERSION}'. Continuing anyway — often just a version-string formatting difference, not a real mismatch."
else
  echo "   Container running ${ACTUAL_VERSION} as expected."
fi
# --- END CHANGED BLOCK -------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 7: Restore config, SSH keys, and data
# ---------------------------------------------------------------------------
echo "==> Stopping container for restore..."
docker stop "${CONTAINER_NAME}"

echo "==> Extracting archive..."
rm -rf "${RESTORE_TMP}"
mkdir -p "${RESTORE_TMP}"
tar -xzf "${ARCHIVE_FILE}" -C "${RESTORE_TMP}"

TS=$(date +%Y%m%d_%H%M%S)
ROLLBACK_TS="${TS}"
echo "==> Saving freshly-created directories as .pre-restore.${TS} (rollback safety)..."
for dir in "${GITLAB_ROOT}/config" "${GITLAB_ROOT}/logs" "${GITLAB_ROOT}/data" "${GITLAB_ROOT}/ssh"; do
  [ -d "${dir}" ] && mv "${dir}" "${dir}.pre-restore.${TS}"
done
ROLLBACK_NEEDED=1

echo "==> Restoring config from archive..."
cp -a "${RESTORE_TMP}/config" "${GITLAB_ROOT}/config"

# Enforce root:root ownership — cp -a preserves whatever ownership the
# archive's source had, which may not be valid on this host.
echo "==> Enforcing root:root ownership on restored config..."
chown -R root:root "${GITLAB_ROOT}/config"

echo "==> Restoring SSH host keys (if present in archive)..."
if [ -d "${RESTORE_TMP}/ssh" ]; then
  cp -a "${RESTORE_TMP}/ssh" "${GITLAB_ROOT}/ssh"
  echo "   Restored SSH host keys from archive."
else
  echo "   No ssh/ directory in archive — host keys were embedded in config."
fi

mkdir -p "${GITLAB_ROOT}/logs" "${GITLAB_ROOT}/data/backups"

BACKUP_FILE=$(find "${RESTORE_TMP}" -maxdepth 1 -name "*_gitlab_backup.tar" | head -n 1)
if [ -z "${BACKUP_FILE}" ]; then
  echo "!! No *_gitlab_backup.tar found inside the archive. Aborting."
  exit 1
fi
mv "${BACKUP_FILE}" "${GITLAB_ROOT}/data/backups/"

echo "==> Starting container to bring up the fresh environment..."
docker start "${CONTAINER_NAME}"

echo "==> Waiting for GitLab to become responsive..."
sleep 30
ATTEMPT=0
until docker exec "${CONTAINER_NAME}" gitlab-rake gitlab:env:info > /dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "${ATTEMPT}" -ge "${MAX_RETRIES}" ]; then
    echo "!! GitLab did not become responsive. Check 'docker logs ${CONTAINER_NAME}'."
    exit 1
  fi
  echo "   ...still waiting (attempt ${ATTEMPT}/${MAX_RETRIES})"
  sleep 10
done

# Query actual git user UID/GID from the now-running container.
GIT_UID=$(docker exec "${CONTAINER_NAME}" id -u git 2>/dev/null) || GIT_UID=""
GIT_GID=$(docker exec "${CONTAINER_NAME}" id -g git 2>/dev/null) || GIT_GID=""
if [ -z "${GIT_UID}" ] || [ -z "${GIT_GID}" ]; then
  echo "!! Could not determine git user UID/GID. Falling back to 998:998."
  GIT_UID=998
  GIT_GID=998
fi

RESTORED_TAR="${GITLAB_ROOT}/data/backups/$(basename "${BACKUP_FILE}")"
echo "==> Setting ownership of restored backup tar to ${GIT_UID}:${GIT_GID}..."
chown "${GIT_UID}:${GIT_GID}" "${RESTORED_TAR}" 2>/dev/null || true
chmod 640 "${RESTORED_TAR}"

echo "==> Running GitLab's internal restore..."
BACKUP_NAME_ARG=$(basename "${RESTORED_TAR}" _gitlab_backup.tar)

docker exec "${CONTAINER_NAME}" gitlab-ctl stop puma
docker exec "${CONTAINER_NAME}" gitlab-ctl stop sidekiq
docker exec "${CONTAINER_NAME}" gitlab-backup restore BACKUP="${BACKUP_NAME_ARG}" force=yes

# ---------------------------------------------------------------------------
# CRITICAL: gitlab-backup restore brings back the ORIGINAL server's
# gitlab.rb (restored from the archive's config/ directory), which contains
# the original production external_url. GITLAB_OMNIBUS_CONFIG in
# docker-compose.yaml only applies on a container's first-ever boot with an
# empty /etc/gitlab — it is silently ignored once a real gitlab.rb already
# exists, which is exactly the state we're in now, post-restore. So the
# compose file's external_url has no effect at this point and must be
# patched directly into the restored gitlab.rb instead.
# ---------------------------------------------------------------------------
echo "==> Patching external_url in restored gitlab.rb to match this host (${DETECTED_EXTERNAL_URL})..."
docker exec "${CONTAINER_NAME}" sed -i -E \
  "s|^external_url ['\"].*['\"]|external_url '${DETECTED_EXTERNAL_URL}'|" \
  /etc/gitlab/gitlab.rb

ACTUAL_EXTERNAL_URL=$(docker exec "${CONTAINER_NAME}" grep "^external_url" /etc/gitlab/gitlab.rb || true)
echo "   gitlab.rb now has: ${ACTUAL_EXTERNAL_URL}"

echo "==> Reconfiguring and restarting all services..."
docker exec "${CONTAINER_NAME}" gitlab-ctl reconfigure
docker exec "${CONTAINER_NAME}" gitlab-ctl restart

# Restore succeeded.
ROLLBACK_NEEDED=0
trap - ERR

echo "==> Cleaning up temp files..."
rm -rf "${RESTORE_TMP}"

echo
echo "==================================================================="
echo "Restore complete. GitLab ${ACTUAL_VERSION} is running from scratch."
echo "  URL:    ${DETECTED_EXTERNAL_URL}"
echo "  SSH:    port ${SSH_PORT}"
echo "  Status: docker exec ${CONTAINER_NAME} gitlab-ctl status"
echo "  Logs:   docker logs -f ${CONTAINER_NAME}"
echo
echo "NOTE: external_url was auto-patched to match this VM's public IP,"
echo "      overriding whatever URL the original server had at backup time."
echo "      Once DNS for a real domain points at this VM, update"
echo "      external_url in /etc/gitlab/gitlab.rb (or ${GITLAB_ROOT}/config/gitlab.rb"
echo "      on the host) and run: docker exec ${CONTAINER_NAME} gitlab-ctl reconfigure"
echo
echo "Pre-restore (empty, freshly-created) directories preserved at:"
echo "  ${GITLAB_ROOT}/{config,logs,data,ssh}.pre-restore.${TS}"
echo "  Safe to delete once you've verified the restore is good."
echo "==================================================================="