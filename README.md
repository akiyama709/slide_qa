# SlideQA

[English](README.md) | [Japanese](README.ja.md)

SlideQA is a macOS presentation Q&A prototype. Open your own PDF, PPTX, or slide-index JSON before presenting. The app builds a local text index, shows source slide numbers/titles/passages, and prepares clearly labeled UNVERIFIED answer drafts. It is not tied to a particular person's presentation.

The current version is v0.32.0, accepted for use after a live microphone check. Drafts remain unverified and can be withheld; the limitations below still apply.

The main workflow is Open presentation, Start once, and Stop. Questions continue without per-question arming or input-mode switching. Return to start stops the current session and closes the presentation. There is no three-question or retry-count cutoff; temporary recognition errors reconnect until the owner stops. Permission denial or unavailable hardware is reported honestly. The normal app has no synthetic-demo selector or self-test tab, and its packaged bundle contains no demo presentation.

## Use the app

1. Open a presentation and inspect its filename, page count, extracted text and import warnings.
2. Use the two visible language choices at the top to choose English or Japanese. Both language names include recognizable native and translated names, so the selector remains understandable in either interface. There is no Settings menu. The choice persists across launches and keeps the current document/session. With no saved choice, the first supported macOS preferred language is used, with English as fallback.
3. Use Questions and drafts and personally press Start when you want Japanese voice input. Only this action can request microphone/speech authorization or begin capture. Stop ends the session.
4. Use Source lookup to inspect original extracted passages. Return to start is available after import and during loading. Opening another presentation cancels the old question session; late results cannot replace the new document.
5. Optional manual question entry has its own Enter question button. It does not start the microphone and is unavailable while voice input is active.

Interface language changes app labels and app-owned status/error messages. It does not translate presentations, filenames, recognized questions, quotations or model prose. Speech recognition and question-boundary detection remain Japanese. System-controlled permission dialogs and unknown service diagnostics may follow macOS language settings.

AI drafts and exact source quotations are displayed separately. Multiple relevant source candidates can be offered to the unverified prototype draft path, with their uncertainty explicitly labeled; unsupported references remain withheld. Citations and model checks do not prove factual correctness; review every draft against the source. Verbal correction, cancellation and stale-result guards remain. There is no speaker identification, so a presenter's speech or rhetorical questions can be mistaken for audience questions.

## Presentation formats

| Format | What is read | Important limits |
| --- | --- | --- |
| PDF | Existing text layer, in file page order | Titles are inferred from the first nonempty text line. Speaker notes are unavailable. |
| PPTX | DrawingML text and speaker notes, in presentation relationship order | Title placeholders are preferred. Missing titles are inferred. Hidden slides keep their positions; note footer/page-number placeholders are excluded. |
| JSON | A validated local slide index | Consecutive page numbers and nonblank titles are required. Prepared answers and custom regex routes are discarded. |

There is no fixed app quota on file bytes, page count or extracted-text length. File data is mapped where supported; hashing and ZIP inflation use chunks, and parsing/indexing check cancellation and macOS memory-pressure notifications. A pressure notification stops the import with an explicit error. Available resources and framework/format support still constrain what can be opened; this is not a promise of unlimited memory or successful import of every document.

PPTX entries are never extracted to disk. Declared lengths, offsets, compression completion and CRC are checked. External relationships are not fetched; DOCTYPE and external XML entities are rejected. UTF-8 XML and ordinary non-ZIP64 stored/deflated ZIP packages are supported. Malformed, encrypted, ZIP64 or protected inputs can be rejected. Legacy PPT, PPTM and Keynote files are unsupported.

The app does not perform OCR, interpret diagrams/images/equations, or recreate layout. Image-only files without usable text are rejected. Empty pages in a mixed document keep their sequence numbers and produce a warning. Inferred titles, complex reading order and printed page numbering need checking against the original. A failed import shows an error rather than continuing with a previous document.

## Requirements and build

- macOS 26 or later; Swift 6.2 or later.
- Python 3 for packaging and publication checks.
- An available on-device SystemLanguageModel with Japanese support for AI drafts.
- Existing on-device Japanese speech recognition and the owner's microphone/speech authorization for voice input.

The app does not install/download models or speech assets, request API keys, or fall back to cloud recognition or an external model API. Unavailable services are reported.

```sh
swift test
python3 Scripts/build_app.py
open dist/SlideQAPrototype.app
```

These use ordinary SwiftPM. The packaging script uses an ad-hoc signature without a certificate or signing key, and refuses to overwrite an existing output. Use --output for another path. It does not launch, install, notarize or change OS settings. No compiled app is published here.

A launch argument can select a file. Fully quit any existing instance first:

```sh
open dist/SlideQAPrototype.app --args --deck /absolute/path/presentation.pptx
```

The same argument accepts .pdf or .json. Keep owner materials outside the repository.

## JSON slide index

A minimal example:

```json
{
  "sourceFile": "local-deck.json",
  "pageCount": 1,
  "slides": [
    {
      "page": 1,
      "title": "Fictional device inspection",
      "text": "Check the condition of the device.",
      "notes": "Fictional text illustrating the file format."
    }
  ]
}
```

Each slide needs page, title, text and a string notes field. Pages must be ordered consecutively from 1 and match pageCount. Supplied JSON cannot have both empty text and empty notes on a slide. Metadata claims such as printedNumbersVerified or sourceSHA256 do not certify an original document. The selected file's digest and extracted-index digest identify bytes and index content respectively; neither proves factual truth, printed numbering or visual fidelity.

## Developer checks

Synthetic fixtures remain for tests and the separate headless developer tool. They are not offered by the app or included as a presentation in its packaged bundle. The developer tool performs source lookup without the model, microphone or GUI:

```sh
swift run SlideQADemoCheck --deck /absolute/path/presentation.pptx --query "humidity"
```

Its output distinguishes a matching page from evidence: a title-only match can be insufficient and have zero quoted passages.

Optional independent-writer fixtures use existing python-pptx and ReportLab. The helper installs nothing and writes only fictional material outside the repository. With both libraries already available:

```sh
python3 Scripts/create_import_fixture.py /tmp/slideqa-import-check/fictional.pptx
python3 Scripts/create_import_fixture.py /tmp/slideqa-import-check/fictional.pdf --format pdf
SLIDEQA_IMPORT_FIXTURES=/tmp/slideqa-import-check swift test
```

That independent-file integration test is enabled only when SLIDEQA_IMPORT_FIXTURES is set. Ordinary tests generate their own parser fixtures.

## Verification and privacy

See [the verification record](docs/verification.md). Version v0.32.0 preserves continuous question handling and isolates synthetic verification from normal diagnostic journals. The owner subsequently checked the normal app with live microphone input and accepted this version. Recognition, question admission and actual answer generation were observed. Some drafts were withheld or encountered model errors, so this does not establish that every question receives an answer.

Default session generators and speech events in regression tests are mocks. Separately, a signed desktop verifier obtained five actual installed-model replies and observed the app's SwiftUI card updates in a visible window. A further model continuity check completed twenty replies from five synthetic question types repeated four times, including two cancellations during inference and recovery on following questions. All twenty completed replies passed model review and matched their fictional facts and citations. The sequence used one Start and rejected input after Stop. These model checks did not use the microphone or capture screen pixels.

The same signed plain-model probe failed with nested ModelManagerServices.ModelManagerError / 1008 inside the coding-agent execution sandbox and answered in an individually approved execution outside it. Launch Services lookup likewise failed inside that sandbox and succeeded outside. This identifies an execution-environment difference; the app contains no sandbox bypass or saved execution exception. Synthetic verification no longer overwrites the owner's capture journal.

Pixel appearance, keyboard/VoiceOver operation, long live sessions and general model quality across new presentations remain unverified. The twenty-reply model check took approximately 2.40–3.83 seconds per completed reply including the stable-completion delay; a three-second limit is not guaranteed. The model can produce incorrect text, withhold drafts or encounter service/decoding errors. Source checks reduce some mistakes but do not prove semantic truth. Acceptance of this checkpoint does not imply those limitations are resolved.

Normal audio is processed in memory without audio-file storage. There is no external model API or material-upload path. Only source, tests, documentation and fictional fixtures belong in this repository. Real decks, notes, recordings, private prompts/answers, logs, credentials, models and build outputs must stay outside it and its history.

```sh
python3 Scripts/check_publication.py --tracked
python3 Scripts/check_localization.py
```

GitHub CI checks publication boundaries, language resources, English-only documentation, the fictional fixture and Python syntax. It does not build Apple frameworks or verify model/audio/GUI operation. No license has been added; that choice remains with the owner.
