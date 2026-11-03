#!/usr/bin/env python3
"""Patch the flutter-create Windows scaffold: name the executable
ViuLiveTV.exe and title the window "Viu Live TV"."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
cmake = ROOT / "windows" / "CMakeLists.txt"
main_cpp = ROOT / "windows" / "runner" / "main.cpp"

for p in (cmake, main_cpp):
    if not p.exists():
        sys.exit(f"missing scaffold file: {p}")

text = cmake.read_text(encoding="utf-8")
text, n = re.subn(r'set\(BINARY_NAME "[^"]*"\)',
                  'set(BINARY_NAME "ViuLiveTV")', text, count=1)
if n != 1:
    sys.exit("BINARY_NAME not found in windows/CMakeLists.txt")
cmake.write_text(text, encoding="utf-8")

text = main_cpp.read_text(encoding="utf-8")
# Current templates call window.Create(L"…", …); older ones used
# CreateAndShow(L"…", …). Replace just the title string either way.
text, n = re.subn(r'(\bCreate(?:AndShow)?\(L")[^"]*(")',
                  r"\g<1>Viu Live TV\g<2>", text, count=1)
if n != 1:
    sys.exit("window title not found in windows/runner/main.cpp")
main_cpp.write_text(text, encoding="utf-8")

print("patched windows scaffold: BINARY_NAME=ViuLiveTV, title='Viu Live TV'")
