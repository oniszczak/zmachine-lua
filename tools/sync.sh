#!/bin/sh
# Keep the plugin's bundled interpreter identical to the tested one.
cd "$(dirname "$0")/.." || exit 1
cp zm/*.lua zmachine.koplugin/zm/
for f in zm/*.lua; do
    cmp -s "$f" "zmachine.koplugin/zm/$(basename "$f")" || { echo "sync failed: $f"; exit 1; }
done
echo "zm/ -> zmachine.koplugin/zm/ in sync"
