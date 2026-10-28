#!/usr/bin/env bash
# Generate the android/ platform scaffolding for the Viu Live TV Android
# TV app and apply the overlay (MainActivity intent bridge, App Actions
# shortcuts, leanback manifest patch, launcher icons + TV banner). The
# platform folder is build-generated and not committed.
#
# Usage:  tv/tool/setup_platforms.sh
# Requires: flutter (3.47.8) on PATH, python3 + Pillow.
set -euo pipefail
cd "$(dirname "$0")/.."

SCAFFOLD="$(mktemp -d)/scaffold"
flutter create --project-name viulivetv --org com.c12n --platforms=android "$SCAFFOLD"

rm -rf android
cp -r "$SCAFFOLD/android" .
cp "$SCAFFOLD/.metadata" . 2>/dev/null || true

MAIN_KOTLIN=android/app/src/main/kotlin/com/c12n/viulivetv
mkdir -p "$MAIN_KOTLIN" android/app/src/main/res/xml
cp android_overlay/kotlin/MainActivity.kt "$MAIN_KOTLIN/MainActivity.kt"
cp android_overlay/res/xml/shortcuts.xml android/app/src/main/res/xml/shortcuts.xml
python3 android_overlay/patch_android.py android

# Launcher icons + TV banner (320x180) from the iOS app icon.
python3 - <<'PYEOF'
from PIL import Image

src = Image.open("../ViuLiveTV/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png").convert("RGB")
for density, px in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)]:
    src.resize((px, px), Image.LANCZOS).save(f"android/app/src/main/res/mipmap-{density}/ic_launcher.png")

banner = Image.new("RGB", (320, 180), (0, 0, 0))
icon = src.resize((180, 180), Image.LANCZOS)
banner.paste(icon, (70, 0))
banner.save("android/app/src/main/res/drawable/banner.png")
print("launcher icons + TV banner written")
PYEOF

flutter pub get
echo "Platforms assembled. Build with: flutter build apk --release"
