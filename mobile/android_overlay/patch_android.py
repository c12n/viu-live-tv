"""Patch the flutter-create generated Android scaffold for Viu Live TV
(mobile phone & tablet edition):
- app label -> "Viu Live TV"
- uses-permission: INTERNET + ACCESS_NETWORK_STATE (the flutter-create
  main manifest omits them — they only ship in the debug/profile
  manifests — and without INTERNET every request fails DNS with
  "Failed host lookup", errno 7; this bit the TV edition's v1.0.0)
- uses-permission: CHANGE_WIFI_MULTICAST_STATE (required by the nsd
  plugin for Chromecast discovery)

Usage: patch_android.py <path-to-generated-android-dir>
"""
import pathlib
import re
import sys


def main() -> None:
    android = pathlib.Path(sys.argv[1])

    manifest_path = android / "app/src/main/AndroidManifest.xml"
    text = manifest_path.read_text()

    text, n = re.subn(r'android:label="[^"]*"', 'android:label="Viu Live TV"', text, count=1)
    if n != 1:
        raise SystemExit("could not patch app label in AndroidManifest.xml")

    if "android.permission.INTERNET" not in text:
        text, n = re.subn(
            r"(<manifest\b[^>]*>)",
            r"\1"
            '\n    <uses-permission android:name="android.permission.INTERNET" />'
            '\n    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />'
            '\n    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />',
            text,
            count=1,
        )
        if n != 1:
            raise SystemExit("could not add network permissions to manifest")

    manifest_path.write_text(text)
    print("patched AndroidManifest.xml for Android mobile")


if __name__ == "__main__":
    main()
