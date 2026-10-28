#!/usr/bin/env python3
"""Validate shipped language resources and English documentation; no GUI or audio."""
import json
from pathlib import Path
import re

ROOT=Path(__file__).resolve().parents[1]
PAIR=re.compile(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");')
CJK=re.compile(r"[\u3000-\u30ff\u3400-\u9fff\uf900-\ufaff\uff66-\uff9f\U00020000-\U000323af]")
TOKEN=re.compile(r"\{[0-9]+\}")
def table(path):
    result={}
    for line in path.read_text().splitlines():
        if not line.strip():continue
        match=PAIR.fullmatch(line)
        if not match:raise ValueError("Invalid strings syntax: "+str(path))
        key,value=(json.loads(x) for x in match.groups())
        if key in result:raise ValueError("Duplicate key: "+key)
        result[key]=value
    return result
def main():
    resource=ROOT/"Sources/SlideQACore/Resources"
    en=table(resource/"en.lproj/Localizable.strings")
    ja=table(resource/"ja.lproj/Localizable.strings")
    assert en and en.keys()==ja.keys()
    for key,value in en.items():
        assert not CJK.search(key+value),"Japanese text in English resource"
        assert set(TOKEN.findall(value))==set(TOKEN.findall(ja[key])),"Argument mismatch"
    for language in ("en","ja"):
        purposes=table(resource/(language+".lproj/InfoPlist.strings"))
        assert set(purposes)=={"NSMicrophoneUsageDescription","NSSpeechRecognitionUsageDescription"}
        if language=="en":assert not any(CJK.search(v) for v in purposes.values())
    for document in [ROOT/"README.md",*(ROOT/"docs").rglob("*.md")]:
        assert not CJK.search(document.read_text()),"Japanese text in English documentation: "+str(document.relative_to(ROOT))
    all_known=set(en)|set(en.values())|set(ja.values())
    for source in (ROOT/"Sources/RealDeckEvidenceApp").glob("*.swift"):
        for key in re.findall(r'(?:ui|language)\.(?:text|format)\("([^"]+)"',source.read_text()):
            assert key in all_known,"Missing UI translation: "+key
    print(json.dumps({"languageEntries":len(en),"languages":["en","ja"],"englishDocsJapaneseText":False,
                      "modelInvoked":False,"microphoneStarted":False}))
if __name__=="__main__":main()
