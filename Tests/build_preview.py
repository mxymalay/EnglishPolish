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
sources = [root / name for name in ['Core.swift','History.swift','API.swift','WhatsAppBridge.swift','Settings.swift','CandidateView.swift','Main.swift','Tests/CandidatePreview.swift']]
subprocess.run(['xcrun','swiftc','-swift-version','5','-target','arm64-apple-macosx13.0','-D','CANDIDATE_PREVIEW','-parse-as-library',*map(str,sources),'-o',str(binary)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(app)
