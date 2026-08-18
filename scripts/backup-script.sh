#!/bin/bash
set -euo pipefail

BACKUP_DEST="/gitlabs/gitlab-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEMP_DIR="/tmp/gitlab-backup-$TIMESTAMP"

mkdir -p "$BACKUP_DEST" "$TEMP_DIR"

echo "==> 1. Running GitLab native backup..."
docker exec gitlab gitlab-backup create

echo "==> 2. Copying configuration files (secrets)..."
cp -r /code/gitlab/config "$TEMP_DIR/config"

echo "==> 3. Copying SSH host keys (if they exist separately)..."
if [ -d "/code/gitlab/ssh" ]; then
    cp -r /code/gitlab/ssh "$TEMP_DIR/ssh"
else
    echo "No separate SSH directory found, skipping (keys are safely inside config)..."
fi

echo "==> 4. Moving the native backup archive..."
BACKUP_FILE=$(ls -t /code/gitlab/data/backups/*_gitlab_backup.tar | head -n1)
mv "$BACKUP_FILE" "$TEMP_DIR/"

echo "==> 5. Creating final archive..."
tar -czf "$BACKUP_DEST/gitlab-complete-$TIMESTAMP.tar.gz" -C "$TEMP_DIR" .

echo "==> 6. Cleaning up..."
rm -rf "$TEMP_DIR"

echo "==> Backup complete! Size:"
du -h "$BACKUP_DEST/gitlab-complete-$TIMESTAMP.tar.gz"

# echo "==> 7. Uploading to Azure Blob Storage via SAS token..."

# source /etc/gitlab-backup/azure-sas-token.conf

# STORAGE_ACCOUNT="<storage_account_name>"
# CONTAINER="gitlabbackups"
# BLOB_NAME="gitlab-complete-$TIMESTAMP.tar.gz"

# az storage blob upload \
#   --blob-url "https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}?${SAS_TOKEN}" \
#   --file "$BACKUP_DEST/gitlab-complete-$TIMESTAMP.tar.gz"

# echo "==> Upload complete."