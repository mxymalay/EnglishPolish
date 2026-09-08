#!/usr/bin/env python3
"""Build/test the standalone macOS app, without changing desktop settings."""
import pathlib
import plistlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

if '--test' in sys.argv:
    executable = BUILD / 'CoreTests'
    run('xcrun', 'swiftc', '-swift-version', '5', ROOT/'Core.swift', ROOT/'API.swift', ROOT/'Tests/main.swift', '-o', executable)
    run(executable)
    async_executable = BUILD / 'APIAsyncTests'
    run('xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', ROOT/'Core.swift', ROOT/'API.swift', ROOT/'Tests/APIAsyncTests.swift', '-o', async_executable)
    run(async_executable)
else:
    app = BUILD / '轻语.app'
    contents = app / 'Contents'
    executable = contents / 'MacOS' / 'EnglishPolish'
    executable.parent.mkdir(parents=True, exist_ok=True)
    with (contents/'Info.plist').open('wb') as f:
        plistlib.dump({
            'CFBundleIdentifier': 'com.xy.english-polish',
            'CFBundleName': '轻语',
            'CFBundleDisplayName': '轻语',
            'CFBundleExecutable': 'EnglishPolish',
            'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '0.1.0',
            'CFBundleVersion': '1',
            'LSMinimumSystemVersion': '13.0',
            'LSUIElement': True,
            'NSHighResolutionCapable': True,
            'NSAccessibilityUsageDescription': '读取 WhatsApp 当前草稿并在你确认后替换润色结果。',
        }, f)
    sources = [ROOT/name for name in ['Core.swift','API.swift','WhatsAppBridge.swift','Settings.swift','Main.swift']]
    run('xcrun','swiftc','-swift-version','5','-O','-target','arm64-apple-macosx13.0','-parse-as-library',*sources,'-o',executable)
    run('codesign','--force','--sign','-','--identifier','com.xy.english-polish',app)
    run('codesign','--verify','--strict',app)
    print(app)
