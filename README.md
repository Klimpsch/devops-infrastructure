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

Every push and PR runs four jobs:

- `shell-lint`         — ShellCheck + shfmt on every `.sh`
- `markdown-lint`      — markdownlint-cli2 + lychee link check on every `.md`
- `ubuntu-workstation` — runs `dev-workstation.sh` on a fresh Ubuntu 24.04 container and asserts tools landed
- `freebsd-hardening`  — runs `bsd_server_hardening.sh` on a real FreeBSD 14.1 VM and asserts sshd is locked down

Runs weekly (Mon 06:00 UTC) to catch upstream package regressions.

## Run lint checks locally

```bash
./scripts/lint.sh
```

Requires: `shellcheck`, `shfmt`, `markdownlint-cli2` (npm), `lychee` (cargo).
