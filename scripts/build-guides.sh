#!/usr/bin/env bash
# Build static HTML guide pages from the content/ tree.
# Run from the site root (where guides/ lives):
#     scripts/build-guides.sh
#
# Layout assumed:
#   content/<slug>/
#       README.md              (main guide, rendered to guides/<slug>/index.html)
#       README-quick.md        (optional, rendered to guides/<slug>/quick.html)
#       images/*.png           (copied to guides/<slug>/images/)
#       *.sh | *.ps1 | *.py    (rendered to guides/<slug>/<basename>.html)
#
# Also picks up observability/README.md -> guides/observability/index.html.
#
# After building, mirrors the rebuilt bundle into production/ if that folder exists.

set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }
have pandoc || { echo "pandoc not found. sudo dnf install -y pandoc"; exit 1; }

SITE_ROOT="$(pwd)"
OUT_DIR="$SITE_ROOT/guides"
mkdir -p "$OUT_DIR"

# Wipe any stale top-level HTML files from previous layouts (keep guide.css
# and any topic subfolders — those get regenerated in place).
find "$OUT_DIR" -maxdepth 1 -type f -name '*.html' -delete 2>/dev/null || true

render_html_shell() {
    # stdin: body HTML fragment
    # args:  title, raw_file_path, depth (how many ../ to reach site root from output)
    local title="$1"
    local raw="$2"
    local depth="$3"
    local root_prefix=""
    for ((i=0; i<depth; i++)); do root_prefix+="../"; done
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>$title — DevOps &amp; Infrastructure</title>
  <link rel="stylesheet" href="${root_prefix}guide.css">
</head>
<body>
<nav>
  <div class="container">
    <a href="${root_prefix}../windows-devops-portfolio.html" class="back-link">
      <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none"
           stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <line x1="19" y1="12" x2="5" y2="12"/><polyline points="12 19 5 12 12 5"/>
      </svg>
      Back to portfolio
    </a>
    <a href="${root_prefix}../$raw" class="raw-link" target="_blank" rel="noopener">$raw</a>
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

# Extract title from the first '# ...' heading in a markdown file.
md_title() {
    local src="$1"
    awk '/^# / { sub(/^# +/, ""); print; exit }' "$src"
}

render_markdown() {
    local src="$1" title="$2" outfile="$3" depth="$4"
    local rel="${src#$SITE_ROOT/}"
    pandoc -f gfm -t html --wrap=none "$src" \
        | render_html_shell "$title" "$rel" "$depth" > "$outfile"
}

render_code() {
    local src="$1" title="$2" outfile="$3" depth="$4"
    local rel="${src#$SITE_ROOT/}"
    local ext lang
    ext="${src##*.}"
    case "$ext" in
        sh|bash)  lang="bash" ;;
        ps1)      lang="powershell" ;;
        yml|yaml) lang="yaml" ;;
        py)       lang="python" ;;
        *)        lang="" ;;
    esac
    {
        printf '# %s\n\n```%s\n' "$(basename "$src")" "$lang"
        cat "$src"
        printf '\n```\n'
    } | pandoc -f gfm -t html --wrap=none --highlight-style=tango \
        | render_html_shell "$title" "$rel" "$depth" > "$outfile"
}

# Render one content folder (or observability/) to guides/<slug>/.
render_topic() {
    local src_dir="$1"
    local slug="$2"

    local out_dir="$OUT_DIR/$slug"
    mkdir -p "$out_dir"

    local title=""
    if [ -f "$src_dir/README.md" ]; then
        title="$(md_title "$src_dir/README.md")"
        [ -n "$title" ] || title="$slug"
        render_markdown "$src_dir/README.md" "$title" "$out_dir/index.html" 1
        echo "   ok   $src_dir/README.md  ->  guides/$slug/index.html"
    else
        title="$slug"
    fi

    if [ -f "$src_dir/README-quick.md" ]; then
        local qtitle
        qtitle="$(md_title "$src_dir/README-quick.md")"
        [ -n "$qtitle" ] || qtitle="$title (Quick)"
        render_markdown "$src_dir/README-quick.md" "$qtitle" "$out_dir/quick.html" 1
        echo "   ok   $src_dir/README-quick.md  ->  guides/$slug/quick.html"
    fi

    if [ -d "$src_dir/images" ]; then
        mkdir -p "$out_dir/images"
        cp "$src_dir/images"/*.png "$out_dir/images/" 2>/dev/null || true
    fi

    # Render any sibling scripts (skip README*.md and images/).
    local f base ext scripttitle
    shopt -s nullglob
    for f in "$src_dir"/*.sh "$src_dir"/*.ps1 "$src_dir"/*.py; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        ext="${base##*.}"
        scripttitle="$base"
        render_code "$f" "$scripttitle" "$out_dir/${base%.$ext}.html" 1
        echo "   ok   $f  ->  guides/$slug/${base%.$ext}.html"
    done
    shopt -u nullglob
}

count=0

# Iterate content/* alphabetically.
for src_dir in "$SITE_ROOT"/content/*/; do
    [ -d "$src_dir" ] || continue
    slug="$(basename "$src_dir")"
    render_topic "${src_dir%/}" "$slug"
    count=$((count + 1))
done

# Observability is its own top-level dir (self-contained).
if [ -f "$SITE_ROOT/observability/README.md" ]; then
    render_topic "$SITE_ROOT/observability" "observability"
    count=$((count + 1))
fi

echo ""
echo "Built $count topics in $OUT_DIR"

# Mirror to production/ if present.
PROD_DIR="$SITE_ROOT/production"
if [ -d "$PROD_DIR" ]; then
    echo ""
    echo "==> Mirroring to $PROD_DIR/"
    if [ -d "$PROD_DIR/guides" ]; then
        rm -rf "$PROD_DIR/guides"
    fi
    cp -r "$OUT_DIR" "$PROD_DIR/guides"

    # Mirror source tree so raw-file links still resolve on the deploy bundle.
    if [ -d "$PROD_DIR/content" ]; then rm -rf "$PROD_DIR/content"; fi
    cp -r "$SITE_ROOT/content/." "$PROD_DIR/content/"

    if [ -d "$SITE_ROOT/observability" ]; then
        if [ -d "$PROD_DIR/observability" ]; then rm -rf "$PROD_DIR/observability"; fi
        cp -rL "$SITE_ROOT/observability" "$PROD_DIR/observability"
    fi
    echo "   ok   guides/, content/, observability/ mirrored"
fi
