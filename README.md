# SlideQA

[English](README.md) | [Japanese](README.ja.md)

SlideQA is a macOS presentation Q&A prototype. Before presenting, choose your own PDF, PPTX, or slide-index JSON with Open presentation. The app builds a local text index and shows the selected filename, format, and number of pages. It is not tied to a particular person's presentation.

The interface supports English and Japanese. Choose Settings > Interface language before presenting. The owner presses Start once to receive Japanese questions continuously and Stop to finish. No per-question arming or input-mode switching is required. File selection belongs to preparation before the session; it is disabled while the microphone or diagnostics are active.

AI text is an UNVERIFIED draft, shown separately from source quotations. Slide numbers, extracted titles, and original extracted passages remain visible. Citations and model checks do not prove factual correctness; review the text before using it. Verbal correction/cancellation and stale-result guards are retained.

## Choose a presentation

An ordinary launch starts at a file-selection screen with no presentation loaded. It starts neither audio capture nor generation. Select a file with Open presentation. The fictional six-slide demo is an explicitly labeled alternative, not the default.

| Format | What is read | Important limits |
| --- | --- | --- |
| PDF | The existing text layer, in file page order | Titles are inferred from the first nonempty text line. Speaker notes are unavailable. |
| PPTX | DrawingML text and speaker-note text, in the presentation's relationship order | Title placeholders are preferred. Missing titles are inferred. Hidden slides retain their positions; note footer/page-number placeholders are excluded. |
| JSON | A validated local slide index | The schema is shown below. Prepared answers and custom regex routes are discarded. |

The app does not perform OCR, interpret diagrams/images/equations, or recreate visual layout. Scanned/image-only files with no usable text are rejected. Empty pages in a mixed document keep their positions and produce a warning. Extracted titles and sequence numbers need checking against the original; printed page numbers are not certified.

PDF/PPTX inputs are limited to 100 MiB and 500 pages/slides. Extracted text and notes are limited to 20,000 characters per field per page and 2,000,000 characters in total. PPTX parsing supports UTF-8 XML and is bounded to 4 MiB per XML part and 32 MiB of read XML. Malformed, encrypted, ZIP64, password-protected or copy-restricted files may be rejected. Legacy PPT, PPTM and Keynote files are unsupported.

PPTX parts are read in memory. Archive paths are not extracted to disk, external relationships are not fetched, and XML external entities/DOCTYPE declarations are rejected.

Choosing another file cancels the old question session and clears its questions, answers, and index. A late completion from an earlier file selection cannot replace the current selection. A failed import leaves an explicit error rather than continuing with the previous file.

## Requirements and build

- macOS 26 or later; Swift 6.2 or later.
- Python 3 for packaging and publication checks.
- An available on-device SystemLanguageModel with Japanese support for AI drafts.
- Available on-device Japanese speech recognition and the owner's microphone/speech authorization for voice input.

The app does not install/download models or speech assets, request API keys, or switch to cloud recognition or an external model API. Unavailable services are reported.

From a local checkout:

```sh
swift test
swift run SlideQADemoCheck
python3 Scripts/build_app.py
open dist/SlideQAPrototype.app
```

These commands use ordinary SwiftPM without disabling its sandbox. The packaging script uses an ad-hoc signature without a certificate or signing key. It refuses to overwrite an existing output; choose another path with --output. It does not launch, install, notarize, or change OS settings. No compiled app is published here.

## Use the app

After import, inspect the filename, page count, source text, and import warnings. Then use the Questions and drafts tab and press Start once when you personally want to start voice input. Only that explicit action can request microphone/speech permission and begin capture. Stop ends the session.

### Interface language

Use the gear menu, Settings > Interface language, to select English or Japanese. The app remembers the selection between launches. Before a selection has been saved, it uses the first supported macOS preferred language and falls back to English. Changing the interface language keeps the selected presentation and current question session intact.

This changes app labels, source headings, and app-owned status/error messages. It does not translate presentation text, filenames, recognized questions, quotations, or generated drafts. Voice input and question-boundary detection remain Japanese; an English interface does not add English speech recognition. macOS-controlled permission dialogs and unrecognized service diagnostics can follow the system language.

Source lookup provides source access without voice input. Diagnostics and manual text entry remain in the secondary Diagnostics tab. No speaker identification is implemented: the presenter's speech or rhetorical questions may be mistaken for audience questions.

An optional launch argument also selects a file. Fully quit an existing instance before using it:

```sh
open dist/SlideQAPrototype.app --args --deck /absolute/path/presentation.pptx
```

The same argument accepts .pdf or .json. Keep all owner materials outside this repository.

## JSON index schema

JSON input is limited to 5 MiB. A minimal example:

```json
{
  "sourceFile": "local-deck.json",
  "pageCount": 1,
  "slides": [
    {
      "page": 1,
      "title": "Fictional device inspection",
      "text": "Check the condition of the device.",
      "notes": "This is fictional text illustrating the file format."
    }
  ]
}
```

Each slide needs page, title, text and a string notes field. Entries must be ordered consecutively from 1, match pageCount, and have nonblank titles. Text and notes cannot both be blank in supplied JSON. The same character/page limits apply; titles are limited to 300 characters.

Input claims such as printedNumbersVerified or sourceSHA256 do not certify an original document. Diagnostics distinguish the selected file's SHA-256 from the extracted-index digest. These identify the file bytes and text index respectively; neither proves factual truth, printed numbering, or visual fidelity.

## Checks without recording

The readiness control in Diagnostics reads service availability and existing authorization metadata without permission requests, recording, generation or downloads.

A separate, explicitly labeled demo check asks three questions about the fictional bundled demo using the on-device model. This does not validate your selected presentation, speech input, rendering or speaker identification. It is disabled for an external --deck launch.

```sh
open dist/SlideQAPrototype.app --args --verify-local-answers-no-audio --disable-microphone
```

This explicit diagnostic stops/saves/exits after at most four minutes. Its results go to SlideQA/Diagnostics under the local user's Application Support directory, outside the repository.

A headless import-and-source check can use the same production file loader:

```sh
swift run SlideQADemoCheck --deck /absolute/path/presentation.pptx --query "humidity"
```

It does not invoke the model, microphone, or GUI. The JSON output distinguishes a matching page from available evidence: a title-only match can be insufficient and have zero quoted passages.

Optional independent-writer fixtures use existing python-pptx (PPTX) or ReportLab (PDF). The helper installs nothing and writes only fictional material outside the repository. With both libraries already available in the chosen Python interpreter:

```sh
python3 Scripts/create_import_fixture.py /tmp/slideqa-import-check/fictional.pptx
python3 Scripts/create_import_fixture.py /tmp/slideqa-import-check/fictional.pdf --format pdf
SLIDEQA_IMPORT_FIXTURES=/tmp/slideqa-import-check swift test
```

The independent-file integration test is enabled only when SLIDEQA_IMPORT_FIXTURES is set. The ordinary tests generate their own small parser fixtures without these Python packages.

## Verification and privacy

See [the verification record](docs/verification.md). The v0.25.0 app compiled locally and 74 tests in 9 suites passed, including production-loader checks on independently written fictional PDF/PPTX files and native language-resource, preference-persistence, fallback, and formatting checks. Compilation, mock session tests, real file import, native inference, real speech, and GUI checks are reported separately. Interactive language switching/file selection, new-deck model quality, real speech, pixels, and GUI/accessibility operation remain unverified for this version.

A response within three seconds has not been achieved or guaranteed. On-device output quality and the frequency of withheld drafts vary. Source/subject/number/relationship/qualification checks reduce some errors but do not prove semantic truth.

Normal audio is processed in memory without audio-file storage. The app has no external model API or material-upload path. Local model errors or unintended instruction following cannot be completely prevented.

Only source, tests, documentation, and a newly written fictional demo belong here. Keep real decks, notes, recordings, private prompts/answers, logs, credentials, models and build outputs outside the repository and its history. Inspect every proposed file; .gitignore is only a helper.

```sh
python3 Scripts/check_publication.py --tracked
python3 Scripts/check_localization.py
```

GitHub CI checks publication boundaries, language resources, English-only documentation, the fictional fixture, and Python syntax. It does not build Apple frameworks or validate model/audio/GUI behavior. No license has been added; that choice remains with the owner.
