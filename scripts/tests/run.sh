#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/../common.sh"
need_python
for script in "$ROOT_DIR"/scripts/*.sh "$ROOT_DIR"/scripts/drill/*.sh "$ROOT_DIR"/scripts/tests/*.sh; do
  bash -n "$script"
done
"$PYTHON_BIN" "$ROOT_DIR/scripts/tests/test_scripts.py"
if command -v pwsh >/dev/null; then
  pwsh -NoLogo -NoProfile -File "$ROOT_DIR/scripts/tests/test-workshop-bootstrap.ps1"
else
  note 'PowerShell bootstrap tests NOT RUN: install PowerShell 7.2+ and run scripts/tests/test-workshop-bootstrap.ps1 separately.'
fi
