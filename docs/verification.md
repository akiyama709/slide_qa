# Verification of v0.32.0

Version v0.32.0 is the current checkpoint accepted after the owner's live microphone check on 2026-10-29. Publication retains that version and its runtime source. Acceptance does not establish that generated drafts are certified, every question succeeds, or all environments have been tested.

## Observed checks

| Check | Observed result | Scope |
| --- | --- | --- |
| Regression suite | 128 tests in 15 suites: 125 passed, three opt-in tests skipped; 8.473 seconds excluding compilation | Independent fictional PDF/PPTX fixtures enabled; default generation and speech events are mocks |
| Continuous session | Eighty mock answers crossed the 64-card display-retention boundary, with cancellation, reconnection and rejection of retired-stream callbacks | One Start; no microphone or real inference |
| Desktop model and card updates | Five installed-model replies matched fictional sources and citations; cancelled cards became hidden and Stop rejected subsequent input | Actual model; app-owned SwiftUI view lifecycle in a visible window; no screen pixels or accessibility tree read |
| Further model continuity | Twenty completed replies from five synthetic question types repeated four times; two in-flight cancellations, two discarded late replies, following-question recovery and a stable definition request without an SDK final event | Actual installed model and production question/session/generator source; no GUI or speech engine in this probe |
| Audio-buffer processing | Actual AVAudioConverter converted an in-memory synthetic 48 kHz stereo signal to 16 kHz mono; production endpoint and buffering paths were exercised | No microphone, speech recognition or real voice; not a speech-to-answer test |
| Normal live app | Recognition updates, final speech events, questions and model requests were observed; a completed answer and withheld/error outcomes were recorded | Owner initiated microphone use and accepted this version; agent did not start capture or operate permission controls |
| Publication and localization | Only approved text sources and a fictional six-slide fixture; 240 matching English/Japanese catalog entries and English-only English documentation | Source checks; no model, microphone or GUI invoked |

The twenty-reply model sequence completed in 55.35 seconds overall. Completed-reply latency ranged from 2.40 to 3.83 seconds, with a median of 2.56 seconds, including the stable-completion delay. All twenty replies passed model review and matched the expected fictional facts and citation-page sets. This was five question types repeated four times, not twenty independently varied examples. The additional driver was outside the published product and used byte-identical production generation, session and incremental-question source. Cancellation and Stop guards passed, but these checks cannot establish the factual quality of arbitrary future drafts.

The live check establishes that the normal microphone-to-question-to-generation path ran. It also contained withheld drafts and a model decoding failure. Its final Stop/window-close snapshot is not a count of all answers previously shown: Stop clears current draft state. No raw questions, source passages, prompts, generated answers, recordings or owner diagnostic journals are published. The accepted normal app has no synthetic presentation or validation resources packaged inside it.

## Continuous operation and recovery

The owner starts capture once. There is no per-question arming step, three-question cutoff or retry-count cutoff. Transient recognition failures reconnect until the owner stops; permission denial and unavailable hardware are reported. The compatibility recognizer seals cancellation as a control turn, so it does not become part of the next question. Stable complete requests can be provisionally admitted without waiting indefinitely for an SDK final notification. Later changed wording retracts the earlier draft and invalidates its generation lease.

Each generation receives its own deadline and invocation lease. The watchdog can retire a stalled call and advance the queue without awaiting a non-cooperative SDK result. Late replies must still match the operation, question, source and revision. At most two SDK invocations can remain alive simultaneously; if both are stuck, new generation is explicitly withheld while question/source handling continues. This bounds outstanding SDK work, not session length, and does not guarantee that the SDK has stopped cancelled work.

Source quotations stay distinct from generated prose. Citations, deterministic source checks and model review reduce some errors but do not prove semantic truth. A model response can be withheld when support checks fail. Service and decoding failures remain visible. The app does not identify speakers, so the presenter's speech or rhetorical questions can be admitted as questions.

## Execution context

The same signed plain-model probe failed with nested ModelManagerServices.ModelManagerError / 1008 inside the coding-agent execution sandbox and answered in an individually approved execution outside it. Launch Services lookup likewise failed inside that execution sandbox and succeeded outside it. The comparison establishes an execution-context difference without assigning an undocumented meaning to internal error 1008. No execution exception, security-setting change or sandbox bypass was saved in the source or normal app.

Synthetic desktop verification is gated by the SLIDEQA_DESKTOP_VALIDATION build flag plus an explicit no-audio verification argument and a matching synthetic manifest/deck. Its hooks are absent from ordinary builds. Safe UI smoke launches and synthetic verification cannot select normal capture diagnostic journals. Before/after journal hashes remained unchanged in the desktop check; launch-configuration regressions cover that boundary.

The model journal records bounded SDK stage/error-domain/code metadata, not raw error descriptions, private userInfo, question text, passages, prompts or answers. Normal capture processes audio in memory and does not store audio files. Only the owner's explicit Start action may request microphone/speech authorization or begin capture. There is no cloud fallback, external model API, material-upload path or automatic asset installation.

## Remaining limits

Pixel appearance, keyboard and VoiceOver operation, long live sessions, robustness across microphones/OS installations and model quality across new presentations have not been established by these checks. A three-second response deadline and a successful answer for every question are not guaranteed. Recognition can fail or revise wording, and the model can generate incorrect text, withhold drafts or return service/decoding errors. Review drafts against the original sources.

PDF/PPTX/JSON import checks cover generated malformed inputs, cancellation/resource-pressure boundaries and independent fictional files. They do not establish OCR, visual or equation understanding, printed-page-number verification or fidelity for all third-party documents. There are no fixed app quotas on bytes/pages/text length; available resources and supported formats still bound import.

## Publication boundary

The public repository contains source, tests, documentation and the fictional six-slide fixture. Real presentations/notes, recordings, private prompts/answers, diagnostic logs, credentials, models, compiled binaries and local execution helpers remain outside it and its Git history.

Before publication, current tracked files and all locally reachable Git blobs were checked for private-source overlap, personal absolute paths, credential/contact patterns and material/build artifacts. Existing remote branches, tags and reachable commit trees were checked separately. These are scoped checks against the known private source and tested patterns, not proof that every possible secret can be detected. Raw private material and diagnostic journals are excluded from the audit deliverables sent to GitHub.

Run the source checks with:

```sh
python3 Scripts/check_publication.py --tracked
python3 Scripts/check_localization.py
```

GitHub CI checks publication boundaries, the fictional fixture, Python syntax, matching language resources and English-only English documentation. It does not build Apple frameworks or test the model, microphone or GUI. Package.swift has no external package dependencies; optional fixture generation uses existing python-pptx and ReportLab installations without bundling them. The repository has no selected license; publication does not add a new reuse license. The local app is ad-hoc signed, and no compiled app or notarized release is published here.
