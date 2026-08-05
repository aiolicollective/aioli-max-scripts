#!/usr/bin/env bash
# ===========================================================================
#  sunpos -- isolated install (macOS / Linux)
#
#  Creates a .venv INSIDE the project folder and installs the dependencies
#  there. Your system Python is never modified. To uninstall: rm -rf .venv
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")"

VENV=".venv"
PY="$VENV/bin/python"

echo
echo "  sunpos -- install"
echo "  -----------------------"

if ! command -v python3 >/dev/null 2>&1; then
    echo "  [X] python3 not found. Install Python 3.9 or newer."
    exit 1
fi

ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
req=$(python3 -c 'import sys; print(sys.version_info[:2] >= (3, 9))')
if [ "$req" != "True" ]; then
    echo "  [X] Python $ver found, 3.9 is the minimum."
    exit 1
fi

if [ ! -x "$PY" ]; then
    echo "  [1/3] creating the .venv virtual environment ..."
    python3 -m venv "$VENV"
else
    echo "  [1/3] .venv already present (Python $ver)."
fi

echo "  [2/3] upgrading pip ..."
"$PY" -m pip install --upgrade pip --quiet --disable-pip-version-check

echo "  [3/3] installing dependencies ..."
"$PY" -m pip install --requirement requirements.txt --quiet --disable-pip-version-check

echo
echo "  Done. Nothing was installed outside .venv/"
echo
echo "  Checking:"
"$PY" -m pytest tests -q 2>/dev/null || "$PY" tests/test_sunpos.py
echo
echo "  Usage:"
echo '    ./run.sh "48.840006, 2.276764" "2026-09-29 19:30" --north 121'
echo '    ./run.sh "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2'
echo
