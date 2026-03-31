#!/bin/bash
set -e

SRC="temp-repo/docs/design"
OUT="public"
TEMPLATE="template.html"

rm -rf "$OUT"
mkdir -p "$OUT"

# Convert each markdown file to HTML
for md in "$SRC"/*.md; do
  fname=$(basename "$md" .md)
  echo "Converting: $fname"
  pandoc "$md" \
    --template="$TEMPLATE" \
    --metadata title="$(head -1 "$md" | sed 's/^#\+ //')" \
    --highlight-style=kate \
    --no-highlight \
    -f markdown -t html5 \
    -o "$OUT/$fname.html"
done

# Copy the existing HTML doc
cp "$SRC/feedback-pipeline-explainer.html" "$OUT/"

# Copy screenshots
if [ -d "$SRC/screenshots" ]; then
  cp -r "$SRC/screenshots" "$OUT/"
fi

# Copy CSS reference
cp "$SRC/token-reference.css" "$OUT/" 2>/dev/null || true

echo "Done! Files in $OUT:"
ls -la "$OUT/"
