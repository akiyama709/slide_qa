#!/usr/bin/env python3
"""Check tracked source/fixture boundaries, not application correctness."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
DEMO="Sources/SlideQACore/Resources/demo.json"
EXCLUDED={".git",".build",".swiftpm","dist","build","__pycache__"}
BLOCKED={".pdf",".ppt",".pptx",".doc",".docx",".wav",".m4a",".mp3",".mp4",".mov",".log",".jsonl",".pem",".key",".p12",".dmg",".pkg",".zip",".onnx",".gguf",".safetensors"}
def inspect(paths):
    issues=[]
    for name in paths:
        p=ROOT/name
        if p.is_symlink() or not p.is_file():issues.append((name,"not a regular source file"));continue
        if any(part.endswith((".app",".dSYM",".mlmodelc")) for part in p.parts) or p.suffix.lower() in BLOCKED:
            issues.append((name,"data or build artifact"));continue
        if p.name.startswith(".env") or (p.suffix.lower()==".json" and name!=DEMO):
            issues.append((name,"unapproved data file"));continue
        data=p.read_bytes()
        try:content=data.decode("utf-8")
        except UnicodeDecodeError:issues.append((name,"non-text file"));continue
        if re.search(r"[/]Users[/][^\s\"'`]+",content):issues.append((name,"personal absolute path"))
        if re.search(r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY)",content):
            issues.append((name,"credential pattern"))
    return issues
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--tracked",action="store_true");args=parser.parse_args()
    if args.tracked:
        output=subprocess.check_output(["git","ls-files","-z"],cwd=ROOT)
        paths=[p for p in output.decode().split("\0") if p]
    else:
        paths=[str(p.relative_to(ROOT)) for p in ROOT.rglob("*") if p.is_file() and not EXCLUDED.intersection(p.relative_to(ROOT).parts)]
    issues=inspect(paths)
    if DEMO not in paths:issues.append((DEMO,"demo fixture missing from publication"))
    demo=json.loads((ROOT/DEMO).read_text())
    if demo.get("sourceFile")!="synthetic-demo.json" or len(demo.get("slides",[]))!=6:
        issues.append((DEMO,"not the six-slide fictional fixture"))
    digest=hashlib.sha256((ROOT/DEMO).read_bytes()).hexdigest()
    if digest not in (ROOT/"Sources/SlideQACore/Deck.swift").read_text():issues.append((DEMO,"loader digest mismatch"))
    print(json.dumps({"filesChecked":len(paths),"syntheticPages":6,"issues":issues,"modelOrMicrophoneInvoked":False},ensure_ascii=False))
    raise SystemExit(bool(issues))
if __name__=="__main__":main()
