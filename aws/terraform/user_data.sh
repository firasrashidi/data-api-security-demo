#!/bin/bash
# Bootstrap a private Amazon Linux 2023 instance.
# This script installs Docker only. It does not receive or write secrets.
set -euo pipefail
exec > >(tee /var/log/secure-api-bootstrap.log) 2>&1

dnf install -y docker
if ! command -v aws >/dev/null 2>&1; then
  dnf install -y awscli
fi
if ! command -v curl >/dev/null 2>&1; then
  dnf install -y curl-minimal
fi

systemctl enable --now docker

install -d -m 0755 /usr/libexec/docker/cli-plugins
if ! docker compose version >/dev/null 2>&1; then
  curl -fsSL \
    -o /usr/libexec/docker/cli-plugins/docker-compose \
    https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64
  chmod 0755 /usr/libexec/docker/cli-plugins/docker-compose
fi

docker compose version
install -d -m 0755 /opt/secure-api
touch /opt/secure-api/.bootstrap-complete
