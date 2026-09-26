import os
import pathlib
import plistlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
app = root / 'build' / 'CandidatePreview.app'
binary = app / 'Contents' / 'MacOS' / 'CandidatePreview'
binary.parent.mkdir(parents=True, exist_ok=True)
with (app / 'Contents' / 'Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier':'com.xy.english-polish.preview',
                  'CFBundleExecutable':'CandidatePreview','CFBundleName':'CandidatePreview',
                  'CFBundlePackageType':'APPL'},stream)
sources = [root / name for name in ['Core.swift','History.swift','API.swift','WhatsAppBridge.swift','Settings.swift','CandidateView.swift','ReasonView.swift','Translate.swift','TranslateView.swift','Main.swift','Tests/CandidatePreview.swift']]
# Same toolchain pairing as build.py: the Command Line Tools Swift driver plus the
# SwiftUI macro plugins shipped with the Xcode platform. Without this the preview
# build dies with "external macro implementation type 'SwiftUIMacros.StateMacro'
# could not be found for macro 'State()'".
environment = os.environ.copy()
clt = pathlib.Path('/Library/Developer/CommandLineTools')
if (clt / 'usr/bin/swiftc').exists():
    environment['DEVELOPER_DIR'] = str(clt)
arguments = ['xcrun','swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-D','CANDIDATE_PREVIEW','-parse-as-library']
plugins = pathlib.Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins')
if plugins.exists():
    arguments += ['-Xfrontend','-plugin-path','-Xfrontend',str(plugins)]
subprocess.run(arguments + [*map(str,sources),'-o',str(binary)],check=True,env=environment)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(app)