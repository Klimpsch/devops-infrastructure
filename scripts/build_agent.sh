#!/usr/bin/env bash
# CI/CD Build Agent Setup for Ubuntu 22.04 / 24.04
#
# Installs SDKs, runtimes, and tooling for typical pipelines.
# Headless, non-interactive, idempotent.
#
# Usage (run as root or via sudo during image build / provisioning):
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/build-agent.sh | sudo bash
#   # or with flags:
#   sudo bash build-agent.sh --skip-dotnet --with-cloud
#
# Flags:
#   --skip-node | --skip-python | --skip-java | --skip-dotnet
#   --skip-go   | --skip-rust   | --skip-docker
#   --with-cloud      install AWS / Azure / GCP CLIs (off by default)
#   --no-ci-user      don't create the 'ci' user (useful in containers)

set -euo pipefail

# ---------- flag parsing ----------
INSTALL_NODE=1
INSTALL_PYTHON=1
INSTALL_JAVA=1
INSTALL_DOTNET=1
INSTALL_GO=1
INSTALL_RUST=1
INSTALL_DOCKER=1
INSTALL_CLOUD=0
CREATE_CI_USER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-node)    INSTALL_NODE=0 ;;
    --skip-python)  INSTALL_PYTHON=0 ;;
    --skip-java)    INSTALL_JAVA=0 ;;
    --skip-dotnet)  INSTALL_DOTNET=0 ;;
    --skip-go)      INSTALL_GO=0 ;;
    --skip-rust)    INSTALL_RUST=0 ;;
    --skip-docker)  INSTALL_DOCKER=0 ;;
    --with-cloud)   INSTALL_CLOUD=1 ;;
    --no-ci-user)   CREATE_CI_USER=0 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1"; exit 1 ;;
  esac
  shift
done

# ---------- helpers ----------
log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m ✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m ! \033[0m %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

export DEBIAN_FRONTEND=noninteractive
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo). Build agents are typically provisioned as root."
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

# ---------- 1. base system ----------
log "apt update + base build toolchain"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  apt-transport-https gnupg2 \
  build-essential pkg-config make cmake ninja-build \
  git git-lfs openssh-client rsync \
  unzip zip xz-utils tar bzip2 p7zip-full \
  jq yq \
  python3 python3-pip python3-venv pipx \
  shellcheck \
  tree tmux htop \
  net-tools dnsutils iputils-ping
ok "base packages"

# ---------- 2. Node (via NodeSource, system-wide) ----------
if [[ $INSTALL_NODE -eq 1 ]]; then
  if ! have node; then
    log "Node.js LTS (NodeSource)"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
    npm install -g pnpm yarn typescript
    ok "Node $(node -v), npm $(npm -v)"
  else
    ok "Node already installed: $(node -v)"
  fi
fi

# ---------- 3. Python (3.10 / 3.11 / 3.12 via deadsnakes) ----------
if [[ $INSTALL_PYTHON -eq 1 ]]; then
  log "Python 3.10/3.11/3.12 (deadsnakes PPA)"
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get update -y
  for v in 3.10 3.11 3.12; do
    apt-get install -y "python${v}" "python${v}-venv" "python${v}-dev" || \
      warn "python${v} not available on this release"
  done
  # pipx-installed tools every pipeline tends to want
  pipx ensurepath --global >/dev/null 2>&1 || true
  for pkg in poetry uv ruff tox pre-commit; do
    pipx install --global "$pkg" 2>/dev/null || \
      pipx upgrade --global "$pkg" 2>/dev/null || \
      warn "pipx $pkg failed"
  done
  ok "Python toolchain"
fi

# ---------- 4. Java (11 / 17 / 21 + Maven + Gradle) ----------
if [[ $INSTALL_JAVA -eq 1 ]]; then
  log "OpenJDK 11, 17, 21 + Maven + Gradle"
  apt-get install -y openjdk-11-jdk-headless openjdk-17-jdk-headless openjdk-21-jdk-headless \
                     maven
  # default Java = 21
  update-alternatives --set java "$(update-alternatives --list java | grep '21' | head -1)" || true

  # Gradle (apt version is often old — install latest via SDKMAN-style tarball)
  GRADLE_VERSION="8.10.2"
  if ! have gradle || [[ "$(gradle --version 2>/dev/null | awk '/^Gradle/ {print $2}')" != "$GRADLE_VERSION" ]]; then
    TMP="$(mktemp -d)"
    curl -fsSL "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip" -o "$TMP/g.zip"
    unzip -q "$TMP/g.zip" -d /opt
    ln -sfn "/opt/gradle-${GRADLE_VERSION}" /opt/gradle
    ln -sf /opt/gradle/bin/gradle /usr/local/bin/gradle
    rm -rf "$TMP"
  fi
  ok "Java $(java -version 2>&1 | head -1), Maven $(mvn -v | awk '/Apache Maven/ {print $3}'), Gradle $(gradle --version | awk '/^Gradle/ {print $2}')"
fi

# ---------- 5. .NET SDK (6 + 8) ----------
if [[ $INSTALL_DOTNET -eq 1 ]]; then
  log ".NET SDK 6.0 + 8.0"
  wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb" -O /tmp/ms.deb
  dpkg -i /tmp/ms.deb && rm /tmp/ms.deb
  apt-get update -y
  apt-get install -y dotnet-sdk-6.0 dotnet-sdk-8.0
  ok ".NET $(dotnet --list-sdks | tr '\n' ' ')"
fi

# ---------- 6. Go ----------
if [[ $INSTALL_GO -eq 1 ]]; then
  GO_VERSION="1.23.4"
  if ! have go || [[ "$(go version 2>/dev/null)" != *"go${GO_VERSION}"* ]]; then
    log "Go ${GO_VERSION}"
    TMP="$(mktemp -d)"
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o "$TMP/go.tgz"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$TMP/go.tgz"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    rm -rf "$TMP"
  fi
  ok "Go $(go version | awk '{print $3}')"
fi

# ---------- 7. Rust (system-wide) ----------
if [[ $INSTALL_RUST -eq 1 ]]; then
  if [[ ! -d /opt/rust ]]; then
    log "Rust (rustup, system-wide at /opt/rust)"
    export RUSTUP_HOME=/opt/rust/rustup
    export CARGO_HOME=/opt/rust/cargo
    curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path
    # expose binaries
    for b in cargo rustc rustup rustfmt clippy-driver cargo-clippy; do
      [[ -f "/opt/rust/cargo/bin/$b" ]] && ln -sf "/opt/rust/cargo/bin/$b" "/usr/local/bin/$b"
    done
    cat > /etc/profile.d/rust.sh <<'EOF'
export RUSTUP_HOME=/opt/rust/rustup
export CARGO_HOME=/opt/rust/cargo
export PATH="$CARGO_HOME/bin:$PATH"
EOF
  fi
  ok "Rust $(rustc --version)"
fi

# ---------- 8. Docker Engine + buildx + compose ----------
if [[ $INSTALL_DOCKER -eq 1 ]]; then
  if ! have docker; then
    log "Docker Engine"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
                       docker-buildx-plugin docker-compose-plugin
  fi
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"
fi

# ---------- 9. kubectl + helm ----------
log "kubectl + helm"
if ! have kubectl; then
  curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
    -o /usr/local/bin/kubectl
  chmod +x /usr/local/bin/kubectl
fi
if ! have helm; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
ok "kubectl $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion), helm $(helm version --short)"

# ---------- 10. GitHub CLI ----------
if ! have gh; then
  log "GitHub CLI"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg status=none
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -y
  apt-get install -y gh
fi
ok "gh $(gh --version | head -1 | awk '{print $3}')"

# ---------- 11. Cloud CLIs (opt-in) ----------
if [[ $INSTALL_CLOUD -eq 1 ]]; then
  log "AWS CLI v2"
  if ! have aws; then
    TMP="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$TMP/aws.zip"
    unzip -q "$TMP/aws.zip" -d "$TMP"
    "$TMP/aws/install" --update
    rm -rf "$TMP"
  fi
  ok "aws $(aws --version 2>&1 | awk '{print $1}')"

  log "Azure CLI"
  have az || curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
  ok "az $(az version --query \"\\\"azure-cli\\\"\" -o tsv 2>/dev/null || echo installed)"

  log "gcloud CLI"
  if ! have gcloud; then
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
      > /etc/apt/sources.list.d/google-cloud-sdk.list
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
      gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    apt-get update -y
    apt-get install -y google-cloud-cli
  fi
  ok "gcloud $(gcloud --version 2>/dev/null | head -1)"
fi

# ---------- 12. Security / scanning tools ----------
log "Trivy + hadolint + syft"
if ! have trivy; then
  curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | \
    gpg --dearmor -o /usr/share/keyrings/trivy.gpg
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb ${CODENAME} main" \
    > /etc/apt/sources.list.d/trivy.list
  apt-get update -y
  apt-get install -y trivy
fi
have hadolint || curl -fsSL "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-$(uname -m)" \
  -o /usr/local/bin/hadolint && chmod +x /usr/local/bin/hadolint
have syft || curl -fsSL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
ok "scanners: trivy, hadolint, syft"

# ---------- 13. 'ci' service user ----------
if [[ $CREATE_CI_USER -eq 1 ]]; then
  if ! id ci >/dev/null 2>&1; then
    log "Creating 'ci' user"
    useradd -m -s /bin/bash -G sudo ci
    echo "ci ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ci
    chmod 440 /etc/sudoers.d/ci
  fi
  [[ $INSTALL_DOCKER -eq 1 ]] && usermod -aG docker ci || true
  ok "user 'ci' ready (home: /home/ci)"
fi

# ---------- 14. cleanup ----------
log "Cleaning apt caches"
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# ---------- summary ----------
echo
ok "Build agent ready."
echo
echo "Installed toolchains:"
[[ $INSTALL_NODE   -eq 1 ]] && echo "  - Node $(node -v 2>/dev/null)"
[[ $INSTALL_PYTHON -eq 1 ]] && echo "  - Python 3.10/3.11/3.12 + poetry/uv/ruff/tox/pre-commit"
[[ $INSTALL_JAVA   -eq 1 ]] && echo "  - JDK 11/17/21, Maven, Gradle"
[[ $INSTALL_DOTNET -eq 1 ]] && echo "  - .NET SDK 6.0, 8.0"
[[ $INSTALL_GO     -eq 1 ]] && echo "  - Go $(go version 2>/dev/null | awk '{print $3}')"
[[ $INSTALL_RUST   -eq 1 ]] && echo "  - Rust (system-wide at /opt/rust)"
[[ $INSTALL_DOCKER -eq 1 ]] && echo "  - Docker + buildx + compose"
echo "  - kubectl, helm, gh, trivy, hadolint, syft, shellcheck, jq, yq"
[[ $INSTALL_CLOUD  -eq 1 ]] && echo "  - aws, az, gcloud"
echo
echo "Next:"
echo "  1. Register the CI runner of your choice (see below) as the 'ci' user."
echo "  2. Reboot or re-login 'ci' so the docker group takes effect."
echo
echo "Runner registration pointers:"
echo "  GitHub Actions:  https://github.com/<org>/<repo>/settings/actions/runners/new"
echo "  GitLab Runner:   https://docs.gitlab.com/runner/install/linux-repository.html"
echo "  Azure DevOps:    https://learn.microsoft.com/azure/devops/pipelines/agents/v2-linux"
echo "  Jenkins agent:   https://www.jenkins.io/doc/book/managing/nodes/"
