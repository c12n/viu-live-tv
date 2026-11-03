#!/usr/bin/env bash
# Assemble the Windows platform scaffold in CI (only sources are
# committed — same pattern as the Android build). The scaffold is
# generated with flutter create, then patched (app/exe name).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f windows/CMakeLists.txt ]; then
  flutter create --project-name viulivetv_mobile --org com.c12n --platforms=windows .
fi
python3 windows_overlay/patch_windows.py
echo "Windows scaffold ready."
