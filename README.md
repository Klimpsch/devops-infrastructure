# devops-infrastructure

Scripts, guides, and CI workflows for Linux / BSD / Windows infrastructure automation.

## Layout

```
scripts/              Automation scripts (bash, PowerShell)
  dev-workstation.sh     Ubuntu dev-box bootstrap
  dev-workstation.ps1    Windows dev-box bootstrap (Chocolatey-based)
  Fedora-Server-Hardening-script.sh
  bsd_server_hardening.sh
  setup-wireguard-fedora.sh
  lint.sh                Run CI lint checks locally
  test-in-container.sh

devops_guides/        Markdown walkthroughs + reference shell scripts
  firewalld-guide.md, ubuntu-firewall-guide.md
  wireguard-{ubuntu,linux-to-windows}-*.md
  Fedora-Server-Hardening-script.md
  port-forwarding-guide.md
  Samba-Setup-for-Windows-on-KVM.md
  virtualization_setup_fedora.sh
  how_to_bsd_hardening.md

.github/workflows/ci.yml   GitHub Actions — lint + multi-OS integration tests
```

## CI

Every push and PR runs three jobs:

- `shell-lint`         — ShellCheck + shfmt on every `.sh`
- `ubuntu-workstation` — runs `dev-workstation.sh` on a fresh Ubuntu 24.04 container and asserts tools landed
- `fedora-hardening`   — runs `Fedora-Server-Hardening-script.sh` in a Fedora container and asserts SSH, sysctl, pwquality, and audit policy landed (systemd-dependent steps are tolerated)

Runs weekly (Mon 06:00 UTC) to catch upstream package regressions.

## Run lint checks locally

```bash
./scripts/lint.sh
```

Requires: `shellcheck`, `shfmt`.
