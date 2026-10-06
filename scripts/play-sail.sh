#!/bin/sh
# Play Doom on Sail: SQLDoom's own client, every tic and frame computed by
# the querygraph/sail fork. Starts the fork's Spark Connect server unless one
# is already listening on the port, runs the client in a window, and stops
# the server it started when the game exits.
#
#   scripts/play-sail.sh
#
#   SAILDOOM_SAIL    the fork's sail binary (scripts/setup.sh records it in
#                    .saildoom.env; default: ~/src/sail-upstream-main/target-fork-release/release/sail)
#   SAILDOOM_PORT    port (default 50053)
#   SAILDOOM_SQLDOOM SQLDoom's checkout (default: ../saildoom-ref/sqldoom)
#
# A level's first tic plans the tic query (about 5 s, once per level); after
# that the game runs at about 32 tics a second.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Paths from scripts/setup.sh, unless set in the environment.
if [ -f "$ROOT/.saildoom.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      SAILDOOM_*) eval "[ -n \"\${$key:-}\" ] || export $key=\"\$value\"" ;;
    esac
  done < "$ROOT/.saildoom.env"
fi
SAIL=${SAILDOOM_SAIL:-$HOME/src/sail-upstream-main/target-fork-release/release/sail}
PORT=${SAILDOOM_PORT:-50053}
SQLDOOM=${SAILDOOM_SQLDOOM:-$ROOT/../saildoom-ref/sqldoom}

listening() { nc -z localhost "$PORT" 2>/dev/null; }

started=""
if ! listening; then
  if [ ! -x "$SAIL" ]; then
    echo "no Sail binary at $SAIL (build querygraph/sail work/recursive-cte, or set SAILDOOM_SAIL)" >&2
    exit 1
  fi
  echo "starting Sail on port $PORT ..."
  SAILDOOM_SAIL="$SAIL" SAILDOOM_PORT="$PORT" SAILDOOM_PYTHON="${SAILDOOM_PYTHON:-}" "$ROOT/scripts/sail-server.sh" > "${TMPDIR:-/tmp}/saildoom-sail.log" 2>&1 &
  started=$!
  i=0
  until listening; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      echo "Sail did not start; see ${TMPDIR:-/tmp}/saildoom-sail.log" >&2
      kill "$started" 2>/dev/null || true
      exit 1
    fi
    sleep 0.5
  done
  trap 'kill "$started" 2>/dev/null || true' EXIT INT TERM
fi

SAIL_REMOTE="sc://localhost:$PORT" "$ROOT/.venv/bin/python" "$ROOT/scripts/play.py" --sqldoom "$SQLDOOM" "$@"
