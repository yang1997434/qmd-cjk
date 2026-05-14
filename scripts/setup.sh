#!/usr/bin/env bash
#
# setup.sh — patch qmd, rebuild FTS, smoke-test.
# Called by install.sh after libsimple.so + dict/ are deployed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/lib/qmd}"

[[ -f "$INSTALL_DIR/libsimple.so" || -f "$INSTALL_DIR/libsimple.dylib" ]] \
  || { echo "ERROR: libsimple not found in $INSTALL_DIR. Run install.sh first." >&2; exit 1; }

echo ""
echo "==> qmd-cjk setup"

echo "[1/3] Patch qmd store.ts ..."
python3 "$SCRIPT_DIR/patch-qmd.py"

echo "[2/3] Rebuild FTS5 in cached indexes ..."
shopt -s nullglob
DB_FILES=("${HOME}/.cache/qmd"/*.sqlite)
shopt -u nullglob
if [[ ${#DB_FILES[@]} -eq 0 ]]; then
  echo "    no kb-*.sqlite found — first qmd run will create FTS with new tokenizer"
else
  for DB in "${DB_FILES[@]}"; do
    name="$(basename "$DB")"
    # Skip backup files (*.sqlite.bak* etc — but bash glob with .sqlite suffix already excludes those)
    bun run "$SCRIPT_DIR/rebuild-fts.ts" "$DB" || {
      echo "    WARN: rebuild failed for $name (skipping)"
      continue
    }
  done
fi

echo "[3/3] Smoke test ..."
# Pick the first non-empty kb-* index for smoke testing; skip the default 'index.sqlite' if empty.
shopt -s nullglob
INDEX_NAME=""
for DB in "${HOME}/.cache/qmd"/*.sqlite; do
  N=$(bun -e "
    import { Database } from 'bun:sqlite';
    const db = new Database('$DB');
    try {
      const r = db.prepare('SELECT COUNT(*) AS c FROM documents WHERE active = 1').get();
      console.log(r.c);
    } catch { console.log(0); }
    db.close();
  " 2>/dev/null)
  if [[ "${N:-0}" -gt 0 ]]; then
    INDEX_NAME="$(basename "$DB" .sqlite)"
    break
  fi
done
shopt -u nullglob

if [[ -n "$INDEX_NAME" ]]; then
  echo "    using index: $INDEX_NAME"
  echo "    CN test '节点':"
  qmd --index "$INDEX_NAME" search '节点' --files -n 1 2>&1 | head -1 | sed 's/^/      /'
  echo "    EN test 'sqlite':"
  qmd --index "$INDEX_NAME" search 'sqlite' --files -n 1 2>&1 | head -1 | sed 's/^/      /'
else
  echo "    (no indexed content yet — skipping smoke test)"
fi

echo ""
echo "✅ qmd-cjk installed. CJK search now works."
echo "   Tip: re-run install.sh after upgrading qmd to re-apply the patch."
