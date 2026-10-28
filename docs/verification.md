# Prototype verification

## Generic-file import (v0.24.0)

2026-10-28, local Apple silicon Mac. PDF/PPTX/JSON selection, local text/notes extraction, a file-selection welcome screen, cancellation of the old session, and late-import rejection are implemented. Ordinary launch loads no presentation. The bundled six-slide demo is an explicit alternative.

- The current app compiled successfully with SwiftPM and the local Apple SDK.
- 67 Swift Testing tests in 8 suites passed in the final run (10.036 seconds, excluding compilation). The independent-writer integration test was enabled and passed.
- Actual files made by existing python-pptx 1.0.2 and ReportLab were read by the production PresentationImporter and EvidenceIndex. The PPTX has reordered slide relationships and speaker-note qualifications. The PDF contains English/Japanese text and a blank page. Tests checked titles, order, exact source passages, retained qualifications, and the absence of a previous file's unrelated topic after switching.
- Parser tests also exercised stored/deflated OOXML, package-root relationships, CDATA, note-footer exclusion, external-reference/DOCTYPE rejection, malformed archives, unsupported inputs, mixed empty pages and late-file-selection rejection.
- A small-deck retrieval defect was found and corrected: a fixed inverse-document-frequency threshold could prevent a specific single term from matching a one-to-three-page deck. The replacement uses frequency relative to the loaded deck, including meaningful two-character Japanese terms. Answer truth/citation guards were not relaxed.
- A title-only match remains insufficient when no body/note passage matches. The headless check reports disposition and quotation count; an empty quotation set is not proof of support.
- Standalone headless checks used the same file loader and source index. They invoke neither the model nor the microphone. Source agreement establishes extraction consistency, not semantic truth.

The first ordinary build was blocked by the local environment's nested sandbox (`sandbox-exec: sandbox_apply: Operation not permitted`). The owner then approved disabling only SwiftPM's internal sandbox for this specific generic build/test/correction cycle. Outer execution restrictions stayed active; no OS/security setting was changed. No exception flag is saved in the project or in normal build instructions.

The continuous-session, verbal-cancellation, correction, stale-result and microphone-ownership tests use synthetic events and mock generation. They do not test real speech or real model output. No recording or new permission request was initiated by these tests.

Not verified for v0.24.0: interactive file-picker operation, pixels, keyboard/VoiceOver use, real inference quality on imported presentations, and actual microphone input. Accessibility labels and shortcuts were reviewed in source only. No OCR or diagram interpretation is implemented. Complex layout reading order, inferred titles and printed page numbering require owner review; the independent files are fictional, not the owner's original presentation.

To reproduce independent-file checks, see the optional fixture commands in the README. Without SLIDEQA_IMPORT_FIXTURES, that one integration test is disabled. Python fixture-writing libraries are optional and are not application runtime dependencies.

## Historical v0.23.0 source milestone

2026-10-27，Apple silicon Mac．

- The public package compiled successfully with Swift 6 strict concurrency and Apple frameworks.
- 57 Swift Testing tests in 7 suites passed. These include synthetic source validation, explicit UNVERIFIED admission versus strict rejection, continuous questions after one start, verbal cancellation, and rejection of delayed results. The generators and speech events in these state tests are mocks.
- The headless demo check loaded exactly six fictional pages and verified source/index consistency. It invoked neither the model nor the microphone.
- Local bundle packaging and strict ad-hoc signature verification passed. The bundle contains only the fictional demo. No compiled app is published in this repository.
- No real microphone test, new GUI/pixel test, or real inference on this public demo was performed for this milestone. On-device output quality varies; no 3-second speech-to-display guarantee is made.

The local restricted development environment required an owner-approved SwiftPM internal sandbox exception for this specific build/test cycle. Outer execution restrictions remained active; no OS setting was changed. This exception is not saved in the project or required by the documented normal build commands.

GitHub CI checks tracked source, credential/path/data boundaries, and the fictional fixture. It does not compile Apple frameworks or verify speech/model/GUI behavior. Native compilation and tests above were performed locally.
