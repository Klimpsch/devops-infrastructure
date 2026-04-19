#!/usr/bin/env bash
# Run the same lint checks as .github/workflows/ci.yml (shell-lint + markdown-lint jobs).
# Usage: scripts/lint.sh
# Exits 0 if all checks pass, 1 otherwise.

set -u
cd "$(dirname "$0")/.."

R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[1;33m'; B=$'\033[0;36m'; N=$'\033[0m'
have() { command -v "$1" >/dev/null 2>&1; }

missing=()
for tool in shellcheck shfmt markdownlint-cli2 lychee; do
    have "$tool" || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "${R}Missing tools:${N} ${missing[*]}"
    echo ""
    echo "Install on Fedora:"
    echo "  sudo dnf install -y shellcheck shfmt nodejs cargo"
    echo "  npm install -g markdownlint-cli2"
    echo "  cargo install lychee"
    exit 1
fi

failed=()
track() {
    if [ "$2" -eq 0 ]; then
        echo "${G}  ok  $1${N}"
    else
        echo "${R}  !!  $1 failed (exit $2)${N}"
        failed+=("$1")
    fi
    echo ""
}

readarray -t shell_files < <(shfmt -f . 2>/dev/null)

if [ "${#shell_files[@]}" -eq 0 ]; then
    echo "${Y}No shell files found — skipping shell checks.${N}"
else
    echo "${B}==> ShellCheck (${#shell_files[@]} files)${N}"
    shellcheck -S warning "${shell_files[@]}"
    track "ShellCheck" $?

    echo "${B}==> shfmt --diff${N}"
    shfmt -d -i 4 -ci "${shell_files[@]}"
    track "shfmt --diff" $?
fi

echo "${B}==> markdownlint${N}"
markdownlint-cli2 "**/*.md"
track "markdownlint" $?

echo "${B}==> lychee (link check)${N}"
lychee --no-progress --exclude-mail \
    --exclude 'your-domain\.com' \
    --exclude 'example\.com' \
    '**/*.md' '**/*.html'
track "lychee" $?

echo "======================================"
if [ "${#failed[@]}" -eq 0 ]; then
    echo "${G}All lint checks passed.${N}"
    exit 0
else
    echo "${R}Failed: ${failed[*]}${N}"
    exit 1
fi
