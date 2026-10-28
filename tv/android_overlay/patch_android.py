#!/usr/bin/env python3
"""Patch the flutter-create generated Android scaffold for Viu Live TV (TV):
- app label -> "Viu Live TV"
- application: TV banner (@drawable/banner)
- uses-feature: leanback + touchscreen, both NOT required (runs on any
  Android TV / box, and still installs on plain Android)
- MainActivity: LEANBACK_LAUNCHER category (shows up in the TV launcher),
  App Actions shortcuts meta-data, and intent filters for the Android TV
  media-search intent + viulivetv:// deep links (Assistant voice support)

Usage: patch_android.py <path-to-generated-android-dir>
"""
import pathlib
import re
import sys

ACTIVITY_EXTRAS = """            <meta-data
                android:name="android.app.shortcuts"
                android:resource="@xml/shortcuts" />
            <intent-filter>
                <action android:name="android.media.action.MEDIA_PLAY_FROM_SEARCH" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data
                    android:scheme="viulivetv"
                    android:host="play" />
            </intent-filter>
        </activity>"""

FEATURES = """    <uses-feature
        android:name="android.software.leanback"
        android:required="false" />
    <uses-feature
        android:name="android.hardware.touchscreen"
        android:required="false" />
    <application"""


def main() -> None:
    android = pathlib.Path(sys.argv[1])

    manifest_path = android / "app/src/main/AndroidManifest.xml"
    text = manifest_path.read_text()

    text, n = re.subn(r'android:label="[^"]*"', 'android:label="Viu Live TV"', text, count=1)
    if n != 1:
        raise SystemExit("could not patch app label in AndroidManifest.xml")

    # TV banner on the application element.
    text, n = re.subn(
        r'(<application\b[^>]*?)(\s*>)',
        r'\1 android:banner="@drawable/banner"\2',
        text,
        count=1,
    )
    if n != 1:
        raise SystemExit("could not add banner to <application>")

    # Leanback/touchscreen features before <application>.
    if "<application" not in text:
        raise SystemExit("no <application> in AndroidManifest.xml")
    text = text.replace("    <application", FEATURES, 1)

    # LEANBACK_LAUNCHER in the main intent-filter (spacing in the
    # generated manifest varies by Flutter version — match loosely).
    leanback = '\n                <category android:name="android.intent.category.LEANBACK_LAUNCHER" />'
    m = re.search(
        r'<category\s+android:name="android\.intent\.category\.LAUNCHER"\s*/>',
        text,
    )
    if m:
        text = text[: m.end()] + leanback + text[m.end():]
    else:
        m2 = re.search(
            r'<action\s+android:name="android\.intent\.action\.MAIN"\s*/>',
            text,
        )
        if not m2:
            raise SystemExit(
                "neither LAUNCHER category nor MAIN action found in manifest"
            )
        text = text[: m2.end()] + leanback + text[m2.end():]

    # Activity extras (shortcuts meta-data + voice/deep-link intent filters).
    if "</activity>" not in text:
        raise SystemExit("no </activity> in AndroidManifest.xml")
    text = text.replace("</activity>", ACTIVITY_EXTRAS, 1)

    manifest_path.write_text(text)
    print("patched AndroidManifest.xml for Android TV")


if __name__ == "__main__":
    main()
