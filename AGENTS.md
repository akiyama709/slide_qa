# SlideQA prototype

This is a macOS source-first presentation Q&A prototype. Keep the Start/Stop workflow continuous; do not require per-question input-mode switching.

- Preserve original citations, numbers, subjects, qualifications, and cancellation/late-result guards.
- An UNVERIFIED draft must never be represented as a certified answer. Exact quotations are quotations, not newly generated prose.
- Never start recording automatically or during agent testing. Only the owner's explicit Start action may request microphone/speech access.
- Do not add cloud fallback, asset downloads, API keys, screen capture, or background uploads.
- Keep real decks, recordings, prompts containing private passages, runtime outputs, binaries, models, and credentials outside this repository and its history.
- Only the fictional six-slide fixture is included. Run `python3 Scripts/check_publication.py --tracked` before publication.
- Build/test with ordinary SwiftPM. Any execution-environment exception requires separate authorization and must not become a saved project setting.
- Distinguish compilation, mock state tests, real model checks, real speech checks, and actual GUI verification in reports.

Useful commands: `swift test`, `swift run SlideQADemoCheck`, `python3 Scripts/build_app.py`.
