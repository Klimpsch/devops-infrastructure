#!/usr/bin/env bash
# Build static HTML guide pages from markdown + script sources.
# Run from the site root (where guides/ lives):
#     scripts/build-guides.sh
#
# Each source is rendered to guides/<basename>.html, wrapped in a consistent
# navigation shell that links back to the portfolio.

set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
have pandoc || { echo "pandoc not found. sudo dnf install -y pandoc"; exit 1; }

# Resolve paths relative to the repo/site root (script is called from site root).
SITE_ROOT="$(pwd)"
OUT_DIR="$SITE_ROOT/guides"
mkdir -p "$OUT_DIR"

# Files to render: SOURCE_PATH|PAGE_TITLE
# SOURCE_PATH is relative to the site root (symlinks are followed automatically).
SOURCES=(
    "devops_guides/firewalld-guide.md|Fedora Firewalls: The Essentials"
    "devops_guides/ubuntu-firewall-guide.md|Ubuntu Firewalls: The Essentials"
    "devops_guides/WireGuard-Fedora-Script-README.md|WireGuard Fedora Setup — README"
    "devops_guides/wireguard-linux-to-windows-guide.md|WireGuard: Fedora ↔ Windows (Full)"
    "devops_guides/wireguard-linux-to-windows-concise.md|WireGuard: Fedora ↔ Windows (Quick)"
    "devops_guides/wireguard-ubuntu-guide.md|WireGuard: Ubuntu ↔ Windows (Full)"
    "devops_guides/wireguard-ubuntu-quick.md|WireGuard: Ubuntu ↔ Windows (Quick)"
    "devops_guides/port-forwarding-guide.md|firewalld Port Forwarding: Host → VM"
    "devops_guides/Samba-Setup-for-Windows-on-KVM.md|Samba Share: Fedora Host ↔ Windows KVM"
    "devops_guides/AD_Exc_setup.md|Windows AD + Exchange Lab on KVM"
    "observability/README.md|Observability Stack: Grafana + InfluxDB + Telegraf"
    "scripts/Fedora-Server-Hardening-script.sh|Fedora 43 Server Hardening Script"
)

render_html_shell() {
    # stdin: body HTML fragment
    # args:  title, raw_file_path
    local title="$1"
    local raw="$2"
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$title — DevOps &amp; Infrastructure</title>
  <link rel="stylesheet" href="guide.css">
</head>
<body>
<nav>
  <div class="container">
    <a href="../windows-devops-portfolio.html" class="back-link">
      <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none"
           stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/>
      </svg>
      Back to portfolio
    </a>
    <a href="../$raw" class="raw-link" target="_blank" rel="noopener">$raw</a>
  </div>
</nav>
<main>
  <article class="guide-content">
$(cat)
  </article>
</main>
</body>
</html>
HTML
}

render_markdown() {
    local src="$1" title="$2" outfile="$3"
    pandoc -f gfm -t html --wrap=none "$src" \
        | render_html_shell "$title" "$src" > "$outfile"
}

# Wrap a code file (.sh, .yml, etc.) in a <pre><code> block, inferring language
# from the extension so pandoc can syntax-highlight.
render_code() {
    local src="$1" title="$2" outfile="$3"
    local ext lang
    ext="${src##*.}"
    case "$ext" in
        sh|bash) lang="bash" ;;
        ps1)     lang="powershell" ;;
        yml|yaml) lang="yaml" ;;
        py)      lang="python" ;;
        *)       lang="" ;;
    esac
    # Pipe the file as a fenced code block through pandoc so we get highlighting.
    {
        printf '# %s\n\n```%s\n' "$(basename "$src")" "$lang"
        cat "$src"
        printf '\n```\n'
    } | pandoc -f gfm -t html --wrap=none --highlight-style=tango \
        | render_html_shell "$title" "$src" > "$outfile"
}

count=0
for entry in "${SOURCES[@]}"; do
    IFS='|' read -r src title <<<"$entry"
    if [ ! -f "$src" ]; then
        echo "  SKIP  $src (not found)"
        continue
    fi

    base="$(basename "$src")"
    name="${base%.*}"
    # A bare "README" would collide across folders — use the parent dir name.
    if [ "$name" = "README" ]; then
        name="$(basename "$(dirname "$src")")"
    fi
    out="$OUT_DIR/$name.html"

    case "$base" in
        *.md|*.markdown) render_markdown "$src" "$title" "$out" ;;
        *)               render_code     "$src" "$title" "$out" ;;
    esac
    echo "   ok   $src  ->  guides/$name.html"
    count=$((count + 1))
done

echo ""
echo "Built $count guides in $OUT_DIR"
