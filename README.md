[English](README.md) | [中文](README.zh-CN.md)

# qmd-cjk

CJK (Chinese / Japanese / Korean) + pinyin full-text search for [qmd](https://github.com/tobi/qmd).

qmd's default FTS5 tokenizer (`porter unicode61`) does not segment CJK runs, so a query like `节点扩容` matches nothing. qmd-cjk patches qmd to load the [wangfenjin/simple](https://github.com/wangfenjin/simple) SQLite FTS5 extension at startup and wraps queries with `simple_query()`. After install, CJK and English search both work in ~0.3 s.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/yang1997434/qmd-cjk/main/install.sh | bash
```

Or clone first if you prefer to read the scripts:

```bash
git clone https://github.com/yang1997434/qmd-cjk.git
cd qmd-cjk
bash install.sh
```

For users in mainland China where `github.com` is slow, pass a mirror:

```bash
GITHUB_PROXY=ghproxy.com bash install.sh
```

## What it does

1. Detect OS + glibc, pick the matching prebuilt `libsimple` from the upstream [wangfenjin/simple Releases](https://github.com/wangfenjin/simple/releases).
2. Drop `libsimple.so`/`libsimple.dylib` and `dict/` into `~/.local/lib/qmd/`.
3. Patch `@tobilu/qmd`'s `store.ts` (5 edits, idempotent, with backup).
4. Rebuild `documents_fts` in every cached qmd index with `tokenize='simple'`.
5. Smoke-test both Chinese and English queries.

## Verify

```bash
qmd search '节点扩容' --files       # CJK phrase, ~0.3 s
qmd search 'hermes 节点' --files    # mixed
qmd search 'database'  --files     # plain English
```

## Platform support

| Platform | glibc | Status |
|----------|-------|--------|
| Linux x86_64 | ≥ 2.32 | ✅ tested (Debian 12) |
| Linux x86_64 | ≥ 2.38 | ✅ uses ubuntu-latest asset |
| Linux aarch64 | ≥ 2.38 | ✅ ubuntu-24.04-arm asset |
| macOS arm64 | n/a | ✅ |
| macOS x86_64 | n/a | ✅ |
| Linux glibc < 2.32 | — | ❌ rebuild libsimple from source |

## Upgrading qmd

When `@tobilu/qmd` is upgraded via npm, the patches are overwritten and CJK search regresses. Re-run the installer:

```bash
bash install.sh   # idempotent — picks up the now-unpatched store.ts and re-applies
```

The installer detects an unpatched store.ts via the absence of the `loadSimpleJiebaIfAvailable` marker.

## Uninstall

```bash
# 1. Restore the original store.ts from the backup
BACKUP=$(ls -t ~/.nvm/versions/node/*/lib/node_modules/@tobilu/qmd/src/store.ts.pre-qmd-cjk-* | head -1)
cp "$BACKUP" "${BACKUP%.pre-qmd-cjk-*}.ts"

# 2. Remove libsimple + dict
rm -rf ~/.local/lib/qmd

# 3. Reinitialize qmd's FTS (will recreate documents_fts with default tokenizer next time qmd writes)
```

## How it works

See [docs/architecture.md](docs/architecture.md) for the 5-patch breakdown and why other approaches (SQLite `trigram`, application-layer jieba wrapper) were rejected.

## License

MIT. Bundles no upstream binaries — `libsimple` is downloaded from wangfenjin/simple at install time and is also MIT-licensed.

## Acknowledgements

- [wangfenjin/simple](https://github.com/wangfenjin/simple) — the SQLite extension that does the heavy lifting (jieba tokenizer + pinyin search).
- [tobi/qmd](https://github.com/tobi/qmd) — the markdown search tool being patched.
