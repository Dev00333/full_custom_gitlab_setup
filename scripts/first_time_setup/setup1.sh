#!/bin/bash
set -euo pipefail
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
sudo reboot