#!/usr/bin/env bash
# Usage: ./test-in-container.sh path/to/script.sh [ubuntu-version]
set -euo pipefail

SCRIPT="${1:?usage: $0 <script.sh> [ubuntu-version]}"
IMAGE="ubuntu:${2:-24.04}"
NAME="setup-test-$$"

[[ -f "$SCRIPT" ]] || { echo "not found: $SCRIPT"; exit 1; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "==> Starting container: $NAME"
docker run -d --name "$NAME" "$IMAGE" sleep infinity >/dev/null

echo "==> Running setup script"
docker exec -i "$NAME" bash -c '
  apt-get update -qq && apt-get install -qq -y sudo curl ca-certificates &&
  useradd -m -s /bin/bash dev && echo "dev ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/dev &&
  cat > /home/dev/script.sh && chown dev:dev /home/dev/script.sh && chmod 755 /home/dev/script.sh &&
  sudo -u dev env -u SUDO_USER bash /home/dev/script.sh
' < "$SCRIPT"

echo
echo "==> Install finished. Dropping into container as 'dev'."
echo "    Type 'exit' to stop and remove the container."
echo
docker exec -it "$NAME" sudo -u dev -i bash
