# devops-infrastructure

Scripts, guides, and CI workflows for Linux / BSD / Windows infrastructure automation.

## Layout

```
content/                  Per-topic folders — guide, scripts, and images together
  <topic>/
    README.md             Main walkthrough (rendered to guides/<topic>/index.html)
    README-quick.md       Optional condensed version (rendered to guides/<topic>/quick.html)
    *.sh | *.ps1 | *.py   Scripts rendered alongside the guide
    images/*.png          Figures referenced from README.md

scripts/                  Project plumbing (not guide content)
  build-guides.sh         Render content/ and observability/ to guides/
  lint.sh                 Run ShellCheck + shfmt locally (same as CI)
  test-in-container.sh

observability/            Grafana + InfluxDB + Telegraf stack (self-contained)

.github/workflows/ci.yml  GitHub Actions — lint + multi-OS integration tests
```

Every guide lives in `content/<topic>/`. For example `content/cml-ospf/` contains the OSPF guide, the Python script that builds the lab, and the verification screenshots, all in one place.

## CI

Every push and PR runs three jobs:

- `shell-lint`         — ShellCheck + shfmt on every `.sh`
- `ubuntu-workstation` — runs `content/dev-workstation-ubuntu/install.sh` on a fresh Ubuntu 24.04 container and asserts tools landed
- `fedora-hardening`   — runs `content/fedora-hardening/harden.sh` in a Fedora container and asserts SSH, sysctl, pwquality, and audit policy landed (systemd-dependent steps are tolerated)

Runs weekly (Mon 06:00 UTC) to catch upstream package regressions.

## Run lint checks locally

```bash
./scripts/lint.sh
```

Requires: `shellcheck`, `shfmt`.

## Build guide HTML

```bash
cd path/to/portfolio-site && ./scripts/build-guides.sh
```

Renders every `content/<topic>/README.md` to `guides/<topic>/index.html`, copies `images/`, and renders any sibling `.sh`/`.ps1`/`.py` to HTML. Mirrors the result into `production/` if that folder exists.
