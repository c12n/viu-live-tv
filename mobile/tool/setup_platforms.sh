#!/usr/bin/env bash
# Generate the android/ platform scaffolding for the Viu Live TV mobile
# (phone & tablet) app and apply the overlay (manifest patch, launcher
# icons). The platform folder is build-generated and not committed.
#
# Usage:  mobile/tool/setup_platforms.sh
# Requires: flutter (3.47.8) on PATH, python3 + Pillow.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAFFOLD="$(mktemp -d)/scaffold"
flutter create --project-name viulivetv_mobile --org com.c12n --platforms=android "$SCAFFOLD"

rm -rf android
cp -r "$SCAFFOLD/android" .
cp "$SCAFFOLD/.metadata" . 2>/dev/null || true

python3 android_overlay/patch_android.py android

# Launcher icons from the iOS app icon.
python3 - <<'PYEOF'
from PIL import Image

src = Image.open("../ViuLiveTV/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png").convert("RGB")
for density, px in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    src.resize((px, px), Image.LANCZOS).save(f"android/app/src/main/res/mipmap-{density}/ic_launcher.png")
print("launcher icons written")
PYEOF

flutter pub get
echo "Platforms assembled. Build with: flutter build apk --release"
