#!/bin/sh
# build.sh — Assemble modular source files into a single index.html
#
# This script reads the HTML skeleton, injects concatenated CSS, JS, and
# translation data (from .po files), and writes the final bundled output
# to filesync/static/index.html.
#
# Usage: ./filesync/build.sh   (from the project root)
#    or: cd filesync && ./build.sh
#
# Requirements: Only standard POSIX tools (cat, sed, awk, sh)

set -e

# Resolve script directory so it works from any working directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OUT_DIR="$SCRIPT_DIR/static"
I18N_DIR="$SCRIPT_DIR/i18n"

# ===== CSS file order =====
# base.css must come first (reset, variables, typography)
# themes.css next (dark theme variable overrides)
# Then structural/component files in any order
CSS_FILES="
  $SRC_DIR/css/base.css
  $SRC_DIR/css/themes.css
  $SRC_DIR/css/layout.css
  $SRC_DIR/css/components.css
  $SRC_DIR/css/file-list.css
  $SRC_DIR/css/modals.css
"

# ===== JS file order =====
# Dependencies flow top-down: i18n and state must come before modules that use them
JS_FILES="
  $SRC_DIR/js/i18n.js
  $SRC_DIR/js/state.js
  $SRC_DIR/js/api.js
  $SRC_DIR/js/ui.js
  $SRC_DIR/js/file-list.js
  $SRC_DIR/js/file-ops.js
  $SRC_DIR/js/drag-drop.js
  $SRC_DIR/js/app.js
"

# Create output directory if needed
mkdir -p "$OUT_DIR"

echo "Building filesync/static/index.html..."

# Step 1: Concatenate CSS
CSS_CONTENT=""
for f in $CSS_FILES; do
    if [ ! -f "$f" ]; then
        echo "ERROR: CSS file not found: $f" >&2
        exit 1
    fi
    CSS_CONTENT="$CSS_CONTENT
$(cat "$f")"
done

# Step 2: Concatenate JS
JS_CONTENT=""
for f in $JS_FILES; do
    if [ ! -f "$f" ]; then
        echo "ERROR: JS file not found: $f" >&2
        exit 1
    fi
    JS_CONTENT="$JS_CONTENT
$(cat "$f")"
done

# Step 3: Generate translation JSON from .po files
if [ ! -x "$SRC_DIR/i18n/po2json.sh" ]; then
    chmod +x "$SRC_DIR/i18n/po2json.sh"
fi
I18N_JSON=$("$SRC_DIR/i18n/po2json.sh" --all "$I18N_DIR")

# Step 4: Read HTML skeleton and inject everything
# We use awk for reliable multi-line replacements
HTML_SKELETON="$SRC_DIR/html/index.html"
if [ ! -f "$HTML_SKELETON" ]; then
    echo "ERROR: HTML skeleton not found: $HTML_SKELETON" >&2
    exit 1
fi

# Write CSS to a temp file for awk to read
CSS_TMP=$(mktemp)
printf '%s' "$CSS_CONTENT" > "$CSS_TMP"

# Write JS to a temp file for awk to read
JS_TMP=$(mktemp)
printf '%s' "$JS_CONTENT" > "$JS_TMP"

# Write i18n to a temp file
I18N_TMP=$(mktemp)
printf '<script>var TRANSLATIONS = %s;</script>' "$I18N_JSON" > "$I18N_TMP"

# Process the HTML skeleton: replace placeholders
awk -v css_file="$CSS_TMP" -v js_file="$JS_TMP" -v i18n_file="$I18N_TMP" '
/\/\* BUILD:CSS \*\// {
    while ((getline line < css_file) > 0) print line
    next
}
/\/\* BUILD:JS \*\// {
    while ((getline line < js_file) > 0) print line
    next
}
/<!-- BUILD:I18N -->/ {
    while ((getline line < i18n_file) > 0) print line
    next
}
{ print }
' "$HTML_SKELETON" > "$OUT_DIR/index.html"

# Clean up temp files
rm -f "$CSS_TMP" "$JS_TMP" "$I18N_TMP"

# Report results
FILE_SIZE=$(wc -c < "$OUT_DIR/index.html" | tr -d ' ')
LINE_COUNT=$(wc -l < "$OUT_DIR/index.html" | tr -d ' ')
echo "Done! Output: $OUT_DIR/index.html"
echo "  Size: ${FILE_SIZE} bytes  Lines: ${LINE_COUNT}"
