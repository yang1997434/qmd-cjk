#!/usr/bin/env bash
#
# qmd-cjk one-liner installer.
#
# Adds Chinese (and CJK + pinyin) full-text search to qmd by patching it to use
# the simple-jieba SQLite FTS5 extension (wangfenjin/simple).
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/yang1997434/qmd-cjk/main/install.sh | bash
#
# Environment overrides:
#   SIMPLE_VERSION   — upstream tag (default: v0.7.1)
#   GITHUB_PROXY     — mirror host without scheme, e.g. ghproxy.com (for users in CN)
#   INSTALL_DIR      — where libsimple.so + dict/ live (default: ~/.local/lib/qmd)
#
set -euo pipefail

SIMPLE_VERSION="${SIMPLE_VERSION:-v0.7.1}"
GITHUB_PROXY="${GITHUB_PROXY:-}"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/lib/qmd}"
REPO_RAW="https://raw.githubusercontent.com/yang1997434/qmd-cjk/main"

proxify() {
  if [[ -n "$GITHUB_PROXY" ]]; then
    echo "https://${GITHUB_PROXY%/}/${1#https://}"
  else
    echo "$1"
  fi
}

echo "==> qmd-cjk installer"

# 1. Detect OS + glibc, pick asset
OS="$(uname -s)"
ARCH="$(uname -m)"

ASSET=""
case "$OS-$ARCH" in
  Linux-x86_64)
    # Capture ldd version line; awk picks the first major.minor token.
    # Disable pipefail locally because head/awk early-exit triggers SIGPIPE upstream.
    set +o pipefail
    GLIBC_VER=$(ldd --version 2>/dev/null \
      | awk 'NR==1 { for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+$/) { print $i; exit } }')
    set -o pipefail
    GLIBC_VER="${GLIBC_VER:-0.0}"
    GLIBC_MAJ="${GLIBC_VER%.*}"
    GLIBC_MIN="${GLIBC_VER##*.}"
    if [[ "$GLIBC_MAJ" -ge 2 && "$GLIBC_MIN" -ge 38 ]]; then
      ASSET="libsimple-linux-ubuntu-latest.zip"
    elif [[ "$GLIBC_MAJ" -ge 2 && "$GLIBC_MIN" -ge 32 ]]; then
      ASSET="libsimple-linux-ubuntu-22.04.zip"
    else
      echo "ERROR: glibc ${GLIBC_VER} is too old (need >= 2.32)." >&2
      echo "       Either upgrade glibc or build libsimple from source." >&2
      exit 1
    fi
    ;;
  Linux-aarch64)
    ASSET="libsimple-linux-ubuntu-24.04-arm.zip"
    ;;
  Darwin-arm64)
    ASSET="libsimple-osx-arm64.zip"
    ;;
  Darwin-x86_64)
    ASSET="libsimple-osx-x64.zip"
    ;;
  *)
    echo "ERROR: unsupported platform $OS-$ARCH" >&2
    exit 1
    ;;
esac
echo "    platform: $OS-$ARCH → $ASSET"

# 2. Download libsimple from upstream Release
URL="https://github.com/wangfenjin/simple/releases/download/${SIMPLE_VERSION}/${ASSET}"
URL="$(proxify "$URL")"
TMP_DIR="$(mktemp -d -t qmd-cjk-XXXXXX)"
trap "rm -rf $TMP_DIR" EXIT
echo "    downloading $URL"
curl -fsSL -o "$TMP_DIR/libsimple.zip" "$URL"

# 3. Extract → install
mkdir -p "$INSTALL_DIR"
unzip -qo "$TMP_DIR/libsimple.zip" -d "$TMP_DIR/extracted/"

SO_SRC=$(find "$TMP_DIR/extracted" -type f \( -name 'libsimple.so' -o -name 'libsimple.dylib' \) | head -1)
DICT_SRC=$(dirname "$SO_SRC")/dict
[[ -f "$SO_SRC" ]] || { echo "ERROR: no libsimple.so in zip" >&2; exit 1; }
[[ -d "$DICT_SRC" ]] || { echo "ERROR: no dict/ in zip" >&2; exit 1; }

cp "$SO_SRC" "$INSTALL_DIR/"
cp -r "$DICT_SRC" "$INSTALL_DIR/"
echo "    installed: $INSTALL_DIR/"

# 4. Fetch scripts (if not running from cloned repo) and run
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo)"
if [[ -n "$SELF_DIR" && -d "$SELF_DIR/scripts" ]]; then
  SCRIPT_DIR="$SELF_DIR/scripts"
  echo "    running scripts from: $SCRIPT_DIR"
else
  SCRIPT_DIR="$TMP_DIR/scripts"
  mkdir -p "$SCRIPT_DIR"
  echo "    fetching scripts from yang1997434/qmd-cjk"
  for f in setup.sh patch-qmd.py rebuild-fts.ts; do
    curl -fsSL -o "$SCRIPT_DIR/$f" "$(proxify "$REPO_RAW/scripts/$f")"
  done
fi

bash "$SCRIPT_DIR/setup.sh"
