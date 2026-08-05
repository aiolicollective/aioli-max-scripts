#!/usr/bin/env bash
# ===========================================================================
#  sunpos -- launcher (macOS / Linux)
#
#    ./run.sh "48.840006, 2.276764" "2026-09-29 19:30" --north 121
#    ./run.sh "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"

PY=".venv/bin/python"

if [ ! -x "$PY" ]; then
    echo "[sunpos] no .venv yet, installing ..."
    ./setup.sh
fi

exec "$PY" sunpos_cli.py "$@"
