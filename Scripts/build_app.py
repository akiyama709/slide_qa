#!/usr/bin/env python3
"""Package a local ad-hoc signed prototype using ordinary SwiftPM; does not launch it."""
from __future__ import annotations

import argparse
import plistlib
from pathlib import Path
import shutil
import subprocess


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / "dist" / "SlideQAPrototype.app")
    parser.add_argument("--binary-dir", type=Path, help="Package a product already built with SwiftPM; does not invoke a compiler")
    args = parser.parse_args()
    app = args.output.expanduser().resolve()
    if app.exists():
        raise SystemExit("Output already exists; choose a different --output path.")
    if args.binary_dir is not None:
        binary_dir = args.binary_dir.expanduser().resolve()
    else:
        subprocess.run(["swift", "build", "-c", "release", "--product", "SlideQAPrototype"], cwd=root, check=True)
        binary_dir = Path(subprocess.check_output(
            ["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip())
    binary = binary_dir / "SlideQAPrototype"
    if not binary.is_file():
        raise SystemExit("SwiftPM did not produce the requested executable.")
    contents = app / "Contents"
    executable_dir = contents / "MacOS"
    resources = contents / "Resources" / "Deck"
    executable_dir.mkdir(parents=True)
    resources.mkdir(parents=True)
    shutil.copy2(binary, executable_dir / "SlideQAPrototype")
    shutil.copy2(root / "Sources" / "SlideQACore" / "Resources" / "demo.json", resources / "demo.json")
    info = {
        "CFBundleExecutable": "SlideQAPrototype",
        "CFBundleIdentifier": "local.slideqa.prototype",
        "CFBundleName": "SlideQA Prototype",
        "CFBundleDisplayName": "SlideQA Prototype",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.24.0",
        "CFBundleVersion": "2400",
        "LSMinimumSystemVersion": "26.0",
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "本人が開始を押した場合だけ，日本語の質問をこのMac内で処理します．",
        "NSSpeechRecognitionUsageDescription": "本人が開始を押した場合だけ，利用可能な端末内音声認識を使用します．",
    }
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(f"Packaged local ad-hoc signed prototype: {app}")
    print("Ad-hoc signing uses no certificate or signing key. No launch, notarization, installation, recording or settings changes were performed.")


if __name__ == "__main__":
    main()
