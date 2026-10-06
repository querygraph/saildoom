#!/bin/sh
# Set up SailDoom from this source checkout: Python environment, SQLDoom's
# client, the querygraph/sail fork (built from source) and the game data.
# Then play with scripts/play-sail.sh.
#
#   scripts/setup.sh
#
# Needs git, curl, tar, cargo (Rust) and uv. Takes about 20 to 40 minutes,
# almost all of it building Sail in release mode.
#
#   SAILDOOM_WORK         where the Sail and SQLDoom checkouts go (default: .build)
#   SAILDOOM_SAIL_BRANCH  the querygraph/sail branch to build (default: saildoom)
#   SAILDOOM_SAIL         an existing fork binary to use instead of building one
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${SAILDOOM_WORK:-$ROOT/.build}
BRANCH=${SAILDOOM_SAIL_BRANCH:-saildoom}
SQLDOOM_COMMIT=95753a2
DATA_URL=https://github.com/querygraph/saildoom/releases/download/play-data-1/freedoom1-play-data.tar.gz
DATA_SHA256=fce9d80e9cf2345aeed1555d3caf52007ee138f2725125a6849a2bd3423cc992

for tool in git curl tar uv; do
  command -v "$tool" >/dev/null || { echo "setup needs $tool" >&2; exit 1; }
done
mkdir -p "$WORK"

echo "== Python 3.12 and .venv"
# The machine's own architecture: Sail links this Python's libpython, and uv
# may also have, say, an x86_64 build installed on an arm64 Mac.
case "$(uname -s)" in Darwin) OS=macos ;; Linux) OS=linux ;; *) OS=$(uname -s | tr A-Z a-z) ;; esac
case "$(uname -m)" in arm64|aarch64) ARCH=aarch64 ;; *) ARCH=$(uname -m) ;; esac
REQUEST=cpython-3.12-$OS-$ARCH
uv python install "$REQUEST" >/dev/null
PYTHON=$(uv python find "$REQUEST")
PYTHON_HOME=$("$PYTHON" -c 'import sys; print(sys.base_prefix)')
uv venv --allow-existing --python "$PYTHON" "$ROOT/.venv" >/dev/null
uv pip install --quiet --python "$ROOT/.venv/bin/python" -r "$ROOT/requirements.txt"

echo "== SQLDoom (cedardb/sqldoom $SQLDOOM_COMMIT): the game's client"
if [ ! -d "$WORK/sqldoom/.git" ]; then
  git clone --quiet https://github.com/cedardb/sqldoom.git "$WORK/sqldoom"
fi
git -C "$WORK/sqldoom" checkout --quiet "$SQLDOOM_COMMIT"

echo "== Freedoom data (Parquet)"
if [ ! -f "$ROOT/data/freedoom1/maps.parquet" ]; then
  mkdir -p "$ROOT/data"
  curl -fsSL -o "$WORK/freedoom1-play-data.tar.gz" "$DATA_URL"
  echo "$DATA_SHA256  $WORK/freedoom1-play-data.tar.gz" | shasum -a 256 -c - >/dev/null
  tar xzf "$WORK/freedoom1-play-data.tar.gz" -C "$ROOT/data"
fi

if [ -n "${SAILDOOM_SAIL:-}" ]; then
  SAIL=$SAILDOOM_SAIL
else
  command -v cargo >/dev/null || { echo "setup needs cargo (https://rustup.rs) to build Sail" >&2; exit 1; }
  echo "== Sail (querygraph/sail $BRANCH), release build"
  if [ ! -d "$WORK/sail/.git" ]; then
    git clone --quiet --depth 1 --branch "$BRANCH" https://github.com/querygraph/sail.git "$WORK/sail"
  else
    git -C "$WORK/sail" fetch --quiet --depth 1 origin "$BRANCH"
    git -C "$WORK/sail" checkout --quiet FETCH_HEAD
  fi
  (cd "$WORK/sail" && PYO3_PYTHON="$PYTHON" cargo build --release -p sail-cli)
  SAIL=$WORK/sail/target/release/sail
fi

cat > "$ROOT/.saildoom.env" <<ENV
# Written by scripts/setup.sh; read by scripts/play-sail.sh.
SAILDOOM_SAIL=$SAIL
SAILDOOM_PYTHON=$PYTHON_HOME
SAILDOOM_SQLDOOM=$WORK/sqldoom
ENV
echo "== ready: scripts/play-sail.sh"
