#!/bin/bash
set -euo pipefail
docker pull gitlab/gitlab-ce:latest
sudo mkdir -p /code/gitlab/config /code/gitlab/logs /code/gitlab/data
docker rm -f gitlab 2>/dev/null || true
docker compose up -d