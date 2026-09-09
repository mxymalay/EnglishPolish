#!/usr/bin/env python3
"""Build/test the standalone macOS app, without changing desktop settings."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)
DESIGNATED_REQUIREMENT = '=designated => identifier "com.xy.english-polish"'

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)

def build_icon(destination):
    iconset = BUILD / 'AppIcon.iconset'
    if iconset.exists(): shutil.rmtree(iconset)
    iconset.mkdir()
    source = ROOT / 'Assets' / 'AppIcon.svg'
    master = BUILD / 'AppIcon-1024.png'
    run('sips','-s','format','png',source,'--out',master)
    for points, scale in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]:
        pixels = points * scale
        suffix = f'@{scale}x' if scale == 2 else ''
        run('sips','-z',pixels,pixels,master,'--out',iconset/f'icon_{points}x{points}{suffix}.png')
    run('iconutil','-c','icns',iconset,'-o',destination)

if '--test' in sys.argv:
    executable = BUILD / 'CoreTests'
    run('xcrun', 'swiftc', '-swift-version', '5', ROOT/'Core.swift', ROOT/'History.swift', ROOT/'API.swift', ROOT/'Tests/main.swift', '-o', executable)
    run(executable)
    async_executable = BUILD / 'APIAsyncTests'
    run('xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', ROOT/'Core.swift', ROOT/'API.swift', ROOT/'Tests/APIAsyncTests.swift', '-o', async_executable)
    run(async_executable)
    history_executable = BUILD / 'HistoryTests'
    run('xcrun','swiftc','-swift-version','5','-parse-as-library',ROOT/'Core.swift',ROOT/'History.swift',ROOT/'Tests/HistoryTests.swift','-o',history_executable)
    run(history_executable)
else:
    app = BUILD / '轻语.app'
    contents = app / 'Contents'
    executable = contents / 'MacOS' / 'EnglishPolish'
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = contents / 'Resources'
    resources.mkdir(parents=True, exist_ok=True)
    build_icon(resources/'AppIcon.icns')
    with (contents/'Info.plist').open('wb') as f:
        plistlib.dump({
            'CFBundleIdentifier': 'com.xy.english-polish',
            'CFBundleName': '轻语',
            'CFBundleDisplayName': '轻语',
            'CFBundleExecutable': 'EnglishPolish',
            'CFBundlePackageType': 'APPL',
            'CFBundleIconFile': 'AppIcon.icns',
            'CFBundleShortVersionString': '0.3.0',
            'CFBundleVersion': '3',
            'LSMinimumSystemVersion': '13.0',
            'LSUIElement': True,
            'NSHighResolutionCapable': True,
            'NSAccessibilityUsageDescription': '读取 WhatsApp 当前草稿并在你确认后替换润色结果。',
        }, f)
    sources = [ROOT/name for name in ['Core.swift','History.swift','API.swift','WhatsAppBridge.swift','Settings.swift','CandidateView.swift','Main.swift']]
    run('xcrun','swiftc','-swift-version','5','-O','-target','arm64-apple-macosx13.0','-parse-as-library',*sources,'-o',executable)
    run('codesign','--force','--sign','-','--identifier','com.xy.english-polish',
        '--requirements',DESIGNATED_REQUIREMENT,app)
    run('codesign','--verify','--strict',app)
    print(app)
