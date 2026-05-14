# Upgrading qmd

When you upgrade `@tobilu/qmd` via npm/bun (e.g. `bun update -g @tobilu/qmd`), the patched `store.ts` is replaced with the upstream version and CJK search regresses to "0 hits".

## Re-applying after an upgrade

```bash
# 1. Verify regression
qmd search '中文测试'  # likely 0 results

# 2. Re-run the installer
curl -sSL https://raw.githubusercontent.com/yang1997434/qmd-cjk/main/install.sh | bash
# or if you have a local clone:
cd ~/path/to/qmd-cjk && bash install.sh
```

The installer's `patch-qmd.py` checks for the `loadSimpleJiebaIfAvailable` marker in `store.ts`. If the marker is missing (upstream version restored), it re-applies all 5 patches with a fresh backup. If the marker is present, it's a no-op.

After patching, FTS5 indexes are rebuilt by `rebuild-fts.ts`, so existing search history continues to work.

## When `patch-qmd.py` fails

If upstream qmd refactors `store.ts` significantly, the anchor strings used by `patch-qmd.py` may no longer match. The script aborts with an explicit error like:

```
ERROR: cannot find `function initializeDatabase`. qmd source layout may have changed.
```

In that case:

1. Open `~/.nvm/versions/node/<ver>/lib/node_modules/@tobilu/qmd/src/store.ts`.
2. Find the new equivalents of the 5 patch sites listed in [architecture.md](architecture.md).
3. Either:
   - **Quick fix**: hand-edit the 5 sites following the patterns in architecture.md, and re-run `bash scripts/setup.sh` to skip the patch step and just rebuild FTS.
   - **Proper fix**: update `patch-qmd.py`'s anchor strings to match the new layout. Submit a PR or open an issue.

## Upgrading `simple` itself

By default, install.sh pins `SIMPLE_VERSION=v0.7.1`. To use a newer release:

```bash
SIMPLE_VERSION=v0.8.0 bash install.sh
```

If the new `simple` release introduces a breaking change to `simple_query()` or `jieba_dict()`, the FTS5 rebuild step will fail loudly. Roll back by re-running with the old version, or report an issue.

## Backups

Every patch run creates a backup next to `store.ts`:

```
store.ts.pre-qmd-cjk-20260513-235800
```

Multiple backups stack up if you patch repeatedly. Periodically prune:

```bash
ls ~/.nvm/versions/node/*/lib/node_modules/@tobilu/qmd/src/store.ts.pre-qmd-cjk-*
# Keep the most recent, delete the rest:
ls -t .../store.ts.pre-qmd-cjk-* | tail -n +2 | xargs rm
```
