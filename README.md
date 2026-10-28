# SlideQA Prototype

[English](README.md) | [日本語](README.ja.md)

SlideQA is a macOS presentation Q&A prototype that searches a local slide index and attempts to produce answer drafts with Apple's on-device model. It is designed for a presenter to press 開始 (Start) once before a presentation, receive Japanese questions continuously, and press 停止 (Stop) when finished. It does not require input-mode changes for each question.

The interface and speech workflow are currently Japanese. This English guide explains the existing prototype; the app has not been localized into English.

Retrieved slide numbers, titles, and source passages are displayed alongside the result. AI text is labeled `UNVERIFIED` and must be reviewed by the presenter. Exact source quotations are identified separately from newly generated prose. A citation or a successful check by the same model does not establish that an answer is factually correct.

Only a newly written, fictional six-slide demo about devices and inspections is included. Real presentation materials, notes, recordings, models, API keys, and compiled apps are excluded from this repository.

## Status and limitations

The published source package was built on a Mac, passed 57 Swift Testing tests in 7 suites, and passed a six-page demo index check. State tests use mock generators and speech events. Local app packaging and ad-hoc signature checks also passed. See the [verification record](docs/verification.md) for the scope of each check.

The following remain unverified for this published candidate:

- The latest GUI on the desktop, real model inference on the public demo, and a complete real Japanese speech-to-answer session.
- Speech-to-display latency. A response within three seconds has not been achieved or guaranteed.

Answer quality and the frequency of withheld answers depend on the local model. Source, subject, number, relationship, and qualification checks reduce some errors; they do not prove semantic truth. Raw sources remain available when a draft is withheld.

There is no speaker identification. The app may treat the presenter's own speech or a rhetorical question as an audience question. Verbal correction and cancellation handling, and guards against displaying stale results, are implemented and covered by mock state tests.

The app reads a text index in JSON. It does not convert PDF/PPTX files, interpret figures, compare the index with an original PDF, or verify printed page numbers. A JSON `page` is the sequential index entry number.

This is a source milestone, not a Developer ID-signed or notarized app distribution.

## Requirements

- macOS 26 or later and a Swift 6.2 or later development environment.
- Python 3 for the packaging and publication-check scripts.
- An available on-device `SystemLanguageModel` with Japanese support for draft generation.
- Available on-device Japanese speech recognition and the owner's microphone/speech authorization for voice input.

The app does not download models or speech assets, request API keys, or switch to cloud recognition or an external model API. Unavailable services are reported rather than installed automatically.

## Build and launch

From a local checkout of this repository:

```sh
swift test
swift run SlideQADemoCheck
python3 Scripts/build_app.py
open dist/SlideQAPrototype.app
```

These commands use ordinary SwiftPM. They do not disable its sandbox.

`build_app.py` builds the app product with SwiftPM, packages it with the fictional demo, and applies an ad-hoc signature without a certificate or signing key. It refuses to overwrite an existing output; use `--output` to select a different destination. The script does not launch, install, notarize, or change OS settings. GUI and model behavior require checking from a normal desktop session.

An ordinary launch starts neither audio capture nor generation. For normal voice use, the owner presses 開始 (Start) once and decides any required OS permission prompts personally. 停止 (Stop) ends the session. No per-question arming or input-mode switching is required.

The main 質問と応答案 tab shows questions and answer drafts. 資料の参照 provides source lookup without voice input. Diagnostics and manual text entry are in the secondary 動作確認 tab; these controls are not required during normal presentation use.

## Use your own local slide index

Keep your JSON and other materials outside the repository, then select the file explicitly:

```sh
open dist/SlideQAPrototype.app --args --deck /absolute/path/deck.json
```

Replace `/absolute/path/deck.json` with your own local file path. A minimal JSON example is:

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

Each slide needs `page`, `title`, `text`, and a string `notes` field. Entries must be ordered consecutively from 1, without duplicates, and match `pageCount`. Titles cannot be blank; text and notes cannot both be blank.

Input limits are 5 MiB of JSON, 500 pages, 300 characters per title, 20,000 characters per text or notes field, and 2,000,000 characters across titles, text, and notes.

The loader does not treat input values such as `printedNumbersVerified` or `sourceSHA256` as proof that an original PDF was checked. Its computed digest identifies the JSON input only. Prepared answers and custom regular-expression routes from external JSON are discarded. Structural validation does not establish factual truth.

## Checks without recording

The readiness control in 動作確認 reads service availability and existing authorization metadata. It does not request permissions, record, generate text, or download assets.

A separate demo check processes three questions about the bundled fictional slides with the on-device model. It distinguishes drafts that passed model review from explicitly unverified drafts. Inspect the actual text and evidence, not just the number of displayed answers. This is not a speech, screen-rendering, or speaker-identification test.

The same diagnostic can be selected explicitly at launch:

```sh
open dist/SlideQAPrototype.app --args --verify-local-answers-no-audio --disable-microphone
```

This mode never starts from an ordinary launch. It stops after at most four minutes, saves its result, and exits. It refuses the demo generation check when an external `--deck` selection is present. Results and progress are saved under `SlideQA/Diagnostics` in the local user's Application Support directory, outside the repository.

This diagnostic is implemented but was not run on the public demo for the recorded milestone.

## Privacy and publication boundaries

Normal audio is processed in memory and is not saved as an audio file. The app has no external model API or material-upload path. Source text is treated as data, but local model errors or unintended instruction following cannot be completely prevented. Owners must decide whether their materials may be used under the applicable handling rules.

Keep real decks, notes, recordings, private prompts and generated answers, runtime logs, keys, and build outputs outside the repository and its history. `.gitignore` helps exclude these files; inspect every proposed file and its history before publication.

To check the publication boundary locally:

```sh
python3 Scripts/check_publication.py --tracked
```

GitHub CI checks tracked source, the fictional fixture, and Python syntax. It does not build Apple frameworks or validate model, audio, or GUI behavior.

A license has not been added to this milestone. The owner retains that choice; no license from a different project has been copied.
