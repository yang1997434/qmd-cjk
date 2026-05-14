#!/usr/bin/env python3
"""
Patch qmd's store.ts to enable simple-jieba (wangfenjin/simple) FTS5 tokenizer
for CJK (Chinese / Japanese / Korean) + pinyin search.

Idempotent: if the patch markers are already present, exits cleanly.

5 patches applied:
  1. Insert `loadSimpleJiebaIfAvailable()` helper above `initializeDatabase`.
  2. Call the helper inside `initializeDatabase` after `sqliteVec.load`.
  3. Change FTS5 schema from `tokenize='porter unicode61'` to `tokenize='simple'`.
  4. Rewrite `buildFTS5Query` to hand raw text to `simple_query()` (no AND-of-prefix).
  5. Wrap SQL `MATCH ?` with `MATCH simple_query(?)`.
"""
import sys
import pathlib
from datetime import datetime


def find_store_ts() -> pathlib.Path:
    """Locate qmd's store.ts. Tries `npm root -g` first (most reliable across
    nvm/setup-node/system installs/hostedtoolcache), then falls back to a
    glob of common install prefixes."""
    import subprocess

    candidates: list[pathlib.Path] = []

    # 1. Ask npm directly — works on macOS Homebrew, nvm, setup-node, Linux distros.
    try:
        root = subprocess.run(
            ["npm", "root", "-g"], capture_output=True, text=True, check=True, timeout=10,
        ).stdout.strip()
        if root:
            for sub in ("@tobilu/qmd/src/store.ts", "qmd/src/store.ts"):
                p = pathlib.Path(root) / sub
                if p.exists():
                    candidates.append(p)
    except Exception:
        pass

    # 2. Fallback: glob common install dirs.
    if not candidates:
        home = pathlib.Path.home()
        for base in [
            home / ".nvm/versions/node",
            home / ".bun/install/global/node_modules",
            pathlib.Path("/opt/hostedtoolcache/node"),     # GitHub Actions setup-node
            pathlib.Path("/usr/local/lib/node_modules"),
            pathlib.Path("/usr/lib/node_modules"),
        ]:
            if base.exists():
                candidates.extend(base.glob("**/@tobilu/qmd/src/store.ts"))
                candidates.extend(base.glob("**/qmd/src/store.ts"))
        candidates = [
            c for c in candidates
            if "node_modules/@tobilu/qmd" in str(c) or "/qmd/src/store.ts" in str(c)
        ]

    if not candidates:
        sys.exit("ERROR: cannot locate qmd's store.ts. Is @tobilu/qmd installed globally?")
    return sorted(set(candidates), key=lambda p: str(p))[0]


def main():
    store_ts = find_store_ts()
    print(f"    target: {store_ts}")
    src = store_ts.read_text()

    if "loadSimpleJiebaIfAvailable" in src:
        print("    already patched, skipping")
        return

    # Backup
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = store_ts.with_name(store_ts.name + f".pre-qmd-cjk-{ts}")
    backup.write_text(src)
    print(f"    backup: {backup.name}")

    patched = src

    # ---- Patch 1+2: loader function + call ----
    needle_init = "function initializeDatabase(db: Database): void {"
    if needle_init not in patched:
        sys.exit("ERROR: cannot find `function initializeDatabase`. qmd source layout may have changed.")
    loader_block = (
        "function loadSimpleJiebaIfAvailable(db: Database): void {\n"
        "  // simple-jieba (wangfenjin/simple) FTS5 tokenizer for CJK + pinyin.\n"
        "  // Best-effort: if .so missing or load fails, FTS falls back to porter unicode61.\n"
        "  const extPath = Bun.env.QMD_SIMPLE_EXT || resolve(homedir(), \".local/lib/qmd/libsimple.so\");\n"
        "  const dictPath = Bun.env.QMD_SIMPLE_DICT || resolve(homedir(), \".local/lib/qmd/dict\");\n"
        "  try {\n"
        "    db.loadExtension(extPath);\n"
        "    db.prepare(`SELECT jieba_dict(?) AS ok`).get(dictPath);\n"
        "  } catch {\n"
        "    // ignore — schema will use porter unicode61 if simple tokenizer not registered\n"
        "  }\n"
        "}\n"
        "\n"
        "function initializeDatabase(db: Database): void {"
    )
    patched = patched.replace(needle_init, loader_block, 1)

    # Patch 2: insert call after sqliteVec catch block
    needle_pragma = "    throw err;\n  }\n  db.exec(\"PRAGMA journal_mode = WAL\");"
    if needle_pragma not in patched:
        sys.exit("ERROR: cannot find PRAGMA journal_mode marker. qmd source layout may have changed.")
    patched = patched.replace(
        needle_pragma,
        "    throw err;\n  }\n  loadSimpleJiebaIfAvailable(db);\n  db.exec(\"PRAGMA journal_mode = WAL\");",
        1,
    )

    # ---- Patch 3: tokenizer ----
    if "tokenize='porter unicode61'" not in patched:
        sys.exit("ERROR: cannot find tokenize='porter unicode61'. Already non-default? Aborting.")
    patched = patched.replace("tokenize='porter unicode61'", "tokenize='simple'", 1)

    # ---- Patch 4: buildFTS5Query body ----
    needle_build = (
        "function buildFTS5Query(query: string): string | null {\n"
        "  const terms = query.split(/\\s+/)\n"
        "    .map(t => sanitizeFTS5Term(t))\n"
        "    .filter(t => t.length > 0);\n"
        "  if (terms.length === 0) return null;\n"
        "  if (terms.length === 1) return `\"${terms[0]}\"*`;\n"
        "  return terms.map(t => `\"${t}\"*`).join(' AND ');\n"
        "}"
    )
    replacement_build = (
        "function buildFTS5Query(query: string): string | null {\n"
        "  // qmd-cjk: hand off raw terms to simple_query() (called in MATCH wrapper)\n"
        "  // for CJK-aware OR/colocation/prefix expansion.\n"
        "  const terms = query.split(/\\s+/)\n"
        "    .map(t => sanitizeFTS5Term(t))\n"
        "    .filter(t => t.length > 0);\n"
        "  if (terms.length === 0) return null;\n"
        "  return terms.join(' ');\n"
        "}"
    )
    if needle_build not in patched:
        sys.exit("ERROR: cannot find buildFTS5Query body. qmd source layout may have changed.")
    patched = patched.replace(needle_build, replacement_build, 1)

    # ---- Patch 5: wrap MATCH ? in simple_query() ----
    needle_match = "WHERE documents_fts MATCH ? AND d.active = 1"
    if needle_match not in patched:
        sys.exit("ERROR: cannot find MATCH clause. qmd source layout may have changed.")
    patched = patched.replace(
        needle_match,
        "WHERE documents_fts MATCH simple_query(?) AND d.active = 1",
        1,
    )

    store_ts.write_text(patched)
    print("    applied 5 patches")


if __name__ == "__main__":
    main()
