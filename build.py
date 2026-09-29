#!/usr/bin/env python3
"""Build/test the standalone macOS app, without changing desktop settings."""
import pathlib
import plistlib
import shutil
import subprocess
import sys
import os
import time

ROOT = pathlib.Path(__file__).resolve().parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)
DESIGNATED_REQUIREMENT = '=designated => identifier "com.xy.english-polish"'
INSTALLED = pathlib.Path.home() / 'Applications' / '轻语.app'
RUNNING_PATTERN = 'Applications/轻语.app/Contents/MacOS/EnglishPolish'


def running_pids():
    result = subprocess.run(['pgrep','-f',RUNNING_PATTERN],capture_output=True,text=True)
    return [int(pid) for pid in result.stdout.split()]


def deploy(app):
    """Every build updates the installed app in ~/Applications, replacing the
    running copy (graceful quit first, SIGKILL for a hung instance) and
    relaunching it only when it was running before."""
    was_running = bool(running_pids())
    if was_running:
        subprocess.run(['osascript','-e','tell application id "com.xy.english-polish" to quit'],check=False)
        for _ in range(40):
            if not running_pids(): break
            time.sleep(0.25)
        for pid in running_pids():
            subprocess.run(['kill','-9',str(pid)],check=False)
        time.sleep(0.5)
    if INSTALLED.exists():
        shutil.rmtree(INSTALLED)
    shutil.copytree(app,INSTALLED,symlinks=True)
    print(f'installed -> {INSTALLED}')
    if was_running:
        subprocess.run(['open',INSTALLED],check=False)

def run(*args, env=None):
    subprocess.run([str(arg) for arg in args], check=True, env=env)

def run_swift(*args, app=False):
    # On this Mac the Xcode 26.6 driver and the Command Line Tools SDK can be
    # installed at different Swift minor versions. Prefer the matching CLT
    # toolchain when it is present; otherwise retain the caller's xcrun choice.
    environment = os.environ.copy()
    clt = pathlib.Path('/Library/Developer/CommandLineTools')
    if (clt / 'usr/bin/swiftc').exists():
        environment['DEVELOPER_DIR'] = str(clt)
    swift_args = list(args)
    if app:
        # SwiftUI's macro implementation is shipped with the Xcode platform
        # SDK, while the matching 6.4 compiler is in the CLT toolchain above.
        # Point the compiler at both explicitly so a newer Xcode SDK cannot be
        # paired with an older Xcode driver by xcrun.
        sdk = pathlib.Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk')
        plugins = pathlib.Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins')
        if sdk.exists(): swift_args += ['-sdk', sdk]
        if plugins.exists(): swift_args += ['-Xfrontend', '-plugin-path', '-Xfrontend', plugins]
    run('xcrun', 'swiftc', *swift_args, env=environment)

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
    run_swift('-swift-version', '5', ROOT/'Core.swift', ROOT/'History.swift', ROOT/'API.swift', ROOT/'Tests/main.swift', '-o', executable)
    run(executable)
    async_executable = BUILD / 'APIAsyncTests'
    run_swift('-swift-version', '5', '-parse-as-library', ROOT/'Core.swift', ROOT/'API.swift', ROOT/'Tests/APIAsyncTests.swift', '-o', async_executable)
    run(async_executable)
    history_executable = BUILD / 'HistoryTests'
    run_swift('-swift-version','5','-parse-as-library',ROOT/'Core.swift',ROOT/'History.swift',ROOT/'Tests/HistoryTests.swift','-o',history_executable)
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
            'CFBundleShortVersionString': '0.4.3',
            'CFBundleVersion': '8',
            'LSMinimumSystemVersion': '13.0',
            'LSUIElement': True,
            'NSHighResolutionCapable': True,
            'NSAccessibilityUsageDescription': '读取 WhatsApp 当前草稿并在你确认后替换润色结果。',
        }, f)
    sources = [ROOT/name for name in ['Core.swift','History.swift','API.swift','WhatsAppBridge.swift','Settings.swift','CandidateView.swift','ReasonView.swift','Translate.swift','TranslateView.swift','Main.swift']]
    run_swift('-swift-version','5','-O','-target','arm64-apple-macosx13.0','-parse-as-library',*sources,'-o',executable,app=True)
    run('codesign','--force','--sign','-','--identifier','com.xy.english-polish',
        '--requirements',DESIGNATED_REQUIREMENT,app)
    run('codesign','--verify','--strict',app)
    deploy(app)
    print(app)
