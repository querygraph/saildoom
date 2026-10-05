#!/bin/sh
# Start a Sail Spark Connect server for SailDoom.
#   SAILDOOM_SAIL      the sail binary (default: sail on PATH)
#   SAILDOOM_PYTHON   a Python install whose libpython the binary links (PyO3)
#   SAILDOOM_PORT port (default 50051)
set -eu
BIN=${SAILDOOM_SAIL:-sail}
if [ -n "${SAILDOOM_PYTHON:-}" ]; then
  export DYLD_LIBRARY_PATH="$SAILDOOM_PYTHON/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  export PYTHONHOME="$SAILDOOM_PYTHON"
fi
# Frames and tics are small queries; extra partitions only add scheduling.
export SAIL_EXECUTION__DEFAULT_PARALLELISM=${SAIL_EXECUTION__DEFAULT_PARALLELISM:-0}
export RUST_LOG=${RUST_LOG:-warn}
exec "$BIN" spark server --port "${SAILDOOM_PORT:-50051}"
