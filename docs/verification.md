# Prototype verification

2026-10-27，Apple silicon Mac．

- The public package compiled successfully with Swift 6 strict concurrency and Apple frameworks.
- 57 Swift Testing tests in 7 suites passed. These include synthetic source validation, explicit UNVERIFIED admission versus strict rejection, continuous questions after one start, verbal cancellation, and rejection of delayed results. The generators and speech events in these state tests are mocks.
- The headless demo check loaded exactly six fictional pages and verified source/index consistency. It invoked neither the model nor the microphone.
- Local bundle packaging and strict ad-hoc signature verification passed. The bundle contains only the fictional demo. No compiled app is published in this repository.
- No real microphone test, new GUI/pixel test, or real inference on this public demo was performed for this milestone. On-device output quality varies; no 3-second speech-to-display guarantee is made.

The local restricted development environment required an owner-approved SwiftPM internal sandbox exception for this specific build/test cycle. Outer execution restrictions remained active; no OS setting was changed. This exception is not saved in the project or required by the documented normal build commands.

GitHub CI checks tracked source, credential/path/data boundaries, and the fictional fixture. It does not compile Apple frameworks or verify speech/model/GUI behavior. Native compilation and tests above were performed locally.
