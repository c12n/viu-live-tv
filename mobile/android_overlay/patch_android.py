"""Patch the flutter-create generated Android scaffold for Viu Live TV
(mobile phone & tablet edition):
- app label -> "Viu Live TV"
- uses-permission: INTERNET + ACCESS_NETWORK_STATE (the flutter-create
  main manifest omits them — they only ship in the debug/profile
  manifests — and without INTERNET every request fails DNS with
  "Failed host lookup", errno 7; this bit the TV edition's v1.0.0)
- uses-permission: CHANGE_WIFI_MULTICAST_STATE (required by the nsd
  plugin for Chromecast discovery)
- uses-permission: POST_NOTIFICATIONS (Remind Me reminders)
- compileSdk -> 36 in app/build.gradle(.kts): dependencies pulled in by
  flutter_local_notifications resolve androidx.core 1.17, whose AAR
  metadata demands compileSdk 36; the generated scaffold pins 35 and
  Gradle fails checkReleaseAarMetadata.
- core library desugaring enabled in the same file (plus the
  desugar_jdk_libs dependency): flutter_local_notifications' AAR
  metadata requires it, the same Gradle check fails without it.

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
            '\n    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />'
            '\n    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />',
            text,
            count=1,
        )
        if n != 1:
            raise SystemExit("could not add network permissions to manifest")

    manifest_path.write_text(text)
    print("patched AndroidManifest.xml for Android mobile")

    for name in ("app/build.gradle.kts", "app/build.gradle"):
        gradle_path = android / name
        if not gradle_path.exists():
            continue
        gtext = gradle_path.read_text()
        gtext, n = re.subn(
            r"compileSdk\s*=\s*(?:flutter\.compileSdkVersion|\d+)",
            "compileSdk = 36",
            gtext,
            count=1,
        )
        if n != 1:
            raise SystemExit(f"could not patch compileSdk in {name}")
        is_kts = name.endswith(".kts")
        if "coreLibraryDesugaring" not in gtext:
            flag = ("isCoreLibraryDesugaringEnabled = true" if is_kts
                    else "coreLibraryDesugaringEnabled true")
            gtext, n = re.subn(
                r"(compileOptions\s*\{)",
                r"\1\n        " + flag,
                gtext,
                count=1,
            )
            if n != 1:
                raise SystemExit(f"could not enable desugaring in {name}")
            dep = ('coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'
                   if is_kts else
                   "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'")
            gtext += f"\ndependencies {{\n    {dep}\n}}\n"
        gradle_path.write_text(gtext)
        print(f"patched compileSdk -> 36 + desugaring in {name}")
        break
    else:
        raise SystemExit("no app build.gradle(.kts) found to patch")


if __name__ == "__main__":
    main()
