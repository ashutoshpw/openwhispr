# Mobile Architecture and Feasibility Plan

> **For agentic workers:** This plan is deliberately staged. Complete the feasibility gates before building product paths that depend on them. Keep the Android stack and the iOS feasibility work separate as described below.

**Goal:** Add a mobile architecture for OpenWhispr's existing account, cloud transcription, and BYOK flows while preserving the user's current Android keyboard, establishing a floating microphone path, and making the required iOS keyboard recording flow an explicit feasibility gate.

**Status:** Implementation started (2026-09-15). This PR is documentation-only; native files, platform projects, and feasibility claims are not included.

**V1 scope:** Existing account and cloud access, plus an initially validated OpenAI-compatible/Groq BYOK path. Local inference and new payments are out of scope. Native capture and transport paths must continue to work when the React Native process is suspended or dead.

## Implementation progress

- [x] **2026-09-15 — Phase 0 discovery:** verified repository instructions, Node/npm tooling, remotes, fork permissions, upstream rules, and the existing CI gates.
- [x] **2026-09-15 — PR1 plan:** staged the documentation-only delivery and the gated Android/iOS sequence.
- [ ] **Android feasibility:** not passed; no physical-device evidence has been accepted yet.
- [ ] **iOS feasibility:** source prototype, workflow, and static checks are implemented; compiler, physical-device, and policy evidence remain pending.
- [ ] **Shared core, mobile foundation, native transport, and product implementation:** pending their stated feasibility gates and predecessor PRs.

## Frozen product answers

These answers come from the product discussion and are requirements for the implementation work:

- **Android:** Keep the user's existing third-party keyboard active and provide a floating microphone control. Replacing that keyboard with an `InputMethodService` is not an acceptable interpretation of the requirement.
- **iOS:** Recording must be controlled from the keyboard flow without a containing-app switch for each dictation. One-time navigation to OpenWhispr to activate a companion-owned recording session is permitted once per session. Treat session expiry, termination, and reboot as session boundaries requiring explicit reactivation. An interruption requires reactivation only when the active session cannot safely recover; test recovery otherwise. Ending or cancelling a dictation, or reaching the 120-second per-dictation cap, ends that dictation only and leaves the activation session usable when the OS permits. Do not promise persistent recording. Block an iOS release if the supported flow cannot be demonstrated.
- **V1 providers:** Keep the existing account and managed cloud path. Validate OpenAI-compatible/Groq BYOK first; do not promise that every desktop provider or model is mobile-ready.

## Proposed defaults to validate

These are implementation defaults, not additional product requirements:

- Target Android 10+ and validate the minimum on physical devices. Target iOS 16+ only if the required keyboard flow is supported by the SDK and device evidence.
- Use tap-to-start and tap-to-stop recording with a hard maximum of 120 seconds. Insert the final transcript automatically when the original target remains valid; a successful insertion does not require another confirmation. If focus or the target window changes, do not silently insert into the new target; offer an explicit retry that revalidates the target.
- Show and hide the Android floating control from actual editable-focus and keyboard-visibility state, with tap controlling recording. A tap-only overlay prototype does not satisfy the acceptance gate.
- Use the managed cloud route and the first validated OpenAI-compatible/Groq BYOK routes. Keep provider, model, policy, expiration, cancellation, and error results in typed contracts shared by the app and native paths.
- Do not add local/native inference or a new payment feature in V1. The existing desktop Whisper/Parakeet binaries and model directories are not mobile implementations.
- Preserve existing entitlements and request only the platform capabilities required by the approved flow. Do not add broad capabilities as a substitute for a product decision.
- Keep transcript history local on the device by default. Do not retain or sync audio by default where the client/API supports that choice. Verify server credential, retention, deletion, and sync contracts before making product claims; backend deletion semantics have not been verified.

## Architecture

### Platform boundaries

- Add a small platform-neutral mobile core for proven route, DTO, policy, and audio-buffer logic. Keep Electron imports out of it.
- Add a separate bare React Native app/package with native Android and iOS projects. The required Android service and the possible iOS keyboard target need native project control; an Expo-managed-only app is not a sufficient default.
- The React Native app owns account screens, provider settings, history, and onboarding. It is not the runtime dependency for recording, transcription, or insertion.
- The Android native service owns microphone capture, the floating overlay, target capture, cloud/BYOK transport, and insertion. It stores its own short-lived session state and uses native secure storage; it must not call `window.electronAPI` or assume the JS process is alive.
- A future supported iOS implementation would use a native keyboard extension for controls and a containing-app-owned audio session, if the feasibility prototype proves that supported IPC/shared-state and lifecycle behavior can meet the flow. This plan does not claim that a Swift keyboard extension can record audio; the feasibility branch documents that direct extension recording is restricted.

### Existing extraction seams

The shared-core PR should extract only behavior demonstrated as needed by the feasibility spike. Candidate seams are:

- `src/helpers/transcriptionRoute.ts` and `src/services/transcriptionBaseUrl.ts` for route contracts and URL normalization.
- `src/helpers/transcriptionFallback.js`, `src/helpers/localSpeechGate.js`, `src/helpers/dictationRouting.js`, and `src/helpers/dictationLifecycle.js` for pure dictation decisions.
- `src/config/agentDetection.ts` only if the mobile flow needs the existing wake-word/address decision.
- `src/utils/audioUtils.js` for PCM conversion, resampling, and RMS calculations.
- Typed DTOs from `src/services/TranscriptionsService.ts` and `src/services/NotesService.ts`, behind a transport interface rather than their current Electron-bound `src/services/cloudApi.ts` calls.

Do not pull these desktop-only boundaries into mobile core: `window.electronAPI` and `preload.js`, `src/helpers/audioManager.js`, local Whisper/Parakeet sidecars, `better-sqlite3` database code, selection/clipboard/paste managers, global hotkeys, Electron windows, or Electron token storage/safeStorage. Preserve the existing desktop import paths with adapters or re-exports where that keeps the desktop behavior stable.

### Native data path

The critical path is independent of the React Native process:

1. The user grants the minimum required Android permissions and taps the floating control.
2. The native service captures audio until explicit stop or the 120-second limit.
3. The native typed client authenticates using the existing account session or a device-secure BYOK value and sends the request through the shared cloud contract.
4. The service receives a final transcript, checks that the original target is still valid, and automatically performs one insertion attempt.
5. A changed or unavailable target produces no insertion into the new target. The UI reports the outcome and exposes an explicit retry path; a verified target does not require a confirmation prompt.

The RN shell can configure the service and display history, but it is not a bridge that the service must call to obtain tokens, make requests, or insert text.

## Stacked PR and worktree sequence

The main Android stack is linear. The iOS feasibility branch is parallel evidence work and is never a dependency of the Android stack. If iOS feasibility passes, the conditional iOS implementation stack branches from the shared mobile foundation after account/auth/cloud and reusable RN screens are available; otherwise those branches are not created:

```text
main
  <- mobile-01-plan
      <- mobile-02-android-feasibility
          <- mobile-03-shared-core
              <- mobile-04-mobile-foundation
                  <- mobile-05-auth-cloud-byok
                      <- mobile-06-android-overlay-insertion
                          <- mobile-07-settings-history-onboarding
                              <- mobile-08-hardening-release

mobile-01-plan
  <- mobile-02-ios-feasibility  (independent, blocked; no shipping implementation)

mobile-07-settings-history-onboarding
  <- mobile-ios-03-keyboard-session  (conditional on iOS feasibility)
      <- mobile-ios-04-onboarding
          <- mobile-ios-05-release
```

Each branch name and worktree final segment must match exactly under `~/.worktrees/ashutoshpw/openwhispr/`.

| PR | Branch and worktree | Dependency and target | Scope | Validation and gate |
| --- | --- | --- | --- | --- |
| 1 | `mobile-01-plan` at `~/.worktrees/ashutoshpw/openwhispr/mobile-01-plan` | Starts from `origin/main`; targets `main` | This plan, frozen answers, architecture boundaries, source links, validation matrix, and staged acceptance gates. | Markdown/link/path checks. No product code. |
| 2A | `mobile-02-android-feasibility` at `~/.worktrees/ashutoshpw/openwhispr/mobile-02-android-feasibility` | Starts from accepted `mobile-01-plan`; targets `mobile-01-plan` | Isolated Kotlin/native spike for Android 10+: foreground microphone service, focus-triggered floating-overlay show/hide, keyboard-visibility transitions, existing third-party keyboard remaining selected, target capture, and insertion into representative editable fields. Do not build the RN product shell here. | Physical-device matrix; overlay and microphone permission flow; actual editable-focus/keyboard show-hide events (not only tapping the overlay); 120-second cap; service restart/error behavior; changed-focus no-silent-insertion test; insertion capability table by app/field. Block production Android work if the requirement cannot be met for the agreed target apps. |
| 2B | `mobile-02-ios-feasibility` at `~/.worktrees/ashutoshpw/openwhispr/mobile-02-ios-feasibility` | Starts from `mobile-01-plan`; targets `mobile-01-plan`; independent of Android | Evidence/decision record and a disposable physical-device prototype only. Test one activation per session through permitted navigation to OpenWhispr, a containing-app-owned audio session controlled from keyboard controls, supported shared-state/IPC, and return to the keyboard without a per-dictation app switch. Test session expiry, termination, reboot, and interruption recovery; require reactivation only when a session cannot safely recover. Ending/cancelling a dictation or reaching the 120-second cap must leave the activation session usable when the OS permits. Do not add direct microphone capture to the keyboard extension or promise persistent recording. | Physical-device/SDK evidence for session expiry, termination/reboot, interruption recovery versus explicit reactivation, per-dictation cancellation/cap behavior, and reviewer-policy assessment. Apple documentation says the custom keyboard extension has no device microphone access; leave this branch **blocked** unless the companion-owned prototype provides reproducible evidence for the required flow. |
| 3 | `mobile-03-shared-core` at `~/.worktrees/ashutoshpw/openwhispr/mobile-03-shared-core` | Starts from `mobile-02-android-feasibility`; targets it. Does not wait on blocked iOS work. | Narrowly extract only the proven route contracts, provider/model DTOs, auth/transport interfaces, policy/error mapping, and PCM/text helpers needed by the Android spike. Keep desktop adapters working. | Focused pure-core tests, existing Node tests, typecheck, format check, and desktop quality gates. No native UI. |
| 4 | `mobile-04-mobile-foundation` at `~/.worktrees/ashutoshpw/openwhispr/mobile-04-mobile-foundation` | Starts from `mobile-03-shared-core`; targets it | Bare React Native package/app, Android and iOS native project scaffolding, typed core package consumption, build/lint/test scripts, and native secure-storage/module seams. No product permissions or unsupported iOS recording. | Android Gradle debug build and tests; RN/TypeScript lint and tests; iOS project compile/check where available; existing repository quality gates. |
| 5 | `mobile-05-auth-cloud-byok` at `~/.worktrees/ashutoshpw/openwhispr/mobile-05-auth-cloud-byok` | Starts from `mobile-04-mobile-foundation`; targets it | Existing account/session integration plus managed cloud and initially validated OpenAI-compatible/Groq BYOK transport. Add direct typed native clients for the Android service (and any future supported iOS companion path) so the native path works when RN is dead. Keep Electron adapter behavior unchanged. | Auth expiry/refresh, logout generation fences, cancellation, route/policy errors, managed cloud, and each selected BYOK provider. Verify native token/key storage and server credential handling against the backend contract; keep secrets out of logs. Validate the mobile API; do not infer support from desktop provider lists. |
| 6 | `mobile-06-android-overlay-insertion` at `~/.worktrees/ashutoshpw/openwhispr/mobile-06-android-overlay-insertion` | Starts from `mobile-05-auth-cloud-byok`; targets it | Production Kotlin foreground service and floating mic overlay, permission/onboarding hooks, PCM capture, direct native transport, target identity checks, and automatic insertion using the feasibility-approved mechanism while leaving the third-party keyboard active. `InputMethodService` is excluded. | Physical Android tests across Android 10+ target devices, representative third-party keyboards/apps, focus-triggered overlay show/hide, keyboard visibility transitions, permission denial, service kill/restart, network/provider errors, 120-second cap, changed focus, secure/noneditable fields, and explicit recovery retry. Review overlay/Accessibility disclosures and Play policy suitability before release. |
| 7 | `mobile-07-settings-history-onboarding` at `~/.worktrees/ashutoshpw/openwhispr/mobile-07-settings-history-onboarding` | Starts from `mobile-06-android-overlay-insertion`; targets it | Account/provider settings, BYOK entry and secure storage, local transcript history, permission education, privacy/retention controls, and recovery states. Keep RN account/provider/settings/history components platform-neutral so a conditional iOS branch can reuse them. No audio sync by default; no new payments. | RN screen tests plus Android device checks for onboarding, logout, key removal, local history, and error/retry states. Confirm no audio/token leakage in logs or persisted data. |
| 8 | `mobile-08-hardening-release` at `~/.worktrees/ashutoshpw/openwhispr/mobile-08-hardening-release` | Starts from `mobile-07-settings-history-onboarding`; targets it | CI/build signing integration using existing entitlements, release configuration, crash/observability redaction, dependency/license review, accessibility/policy disclosures, and final device matrix. | Existing desktop CI plus mobile lint/typecheck/unit tests, Android release build, physical-device smoke tests, and documented limits. iOS remains blocked and has no release artifact until a separate supported feasibility decision exists. |
| Conditional iOS 3 | `mobile-ios-03-keyboard-session` at `~/.worktrees/ashutoshpw/openwhispr/mobile-ios-03-keyboard-session` | Only after `mobile-02-ios-feasibility` passes; starts from `mobile-07-settings-history-onboarding`; targets it | Native keyboard controls, containing-app-owned audio-session IPC/shared state, one activation per session, explicit reactivation after session expiry/termination/reboot or unrecoverable interruption, lifecycle handling, and no persistent-recording promise. Ending/cancelling a dictation or reaching the 120-second cap should leave the activation session usable when the OS permits. Reuse the shared RN account/settings/history screens from the predecessor; never put microphone capture in the extension without new supported evidence. | Physical iOS device and SDK tests for no per-dictation app switch, session expiry, termination/reboot, interruption recovery versus explicit reactivation, per-dictation cancellation/cap behavior, auth expiry, and policy review. Do not create if feasibility remains blocked. |
| Conditional iOS 4 | `mobile-ios-04-onboarding` at `~/.worktrees/ashutoshpw/openwhispr/mobile-ios-04-onboarding` | Starts from `mobile-ios-03-keyboard-session`; targets it | iOS-specific permission/setup and activation guidance layered onto the shared account/provider settings and local history screens; do not duplicate the RN companion UI. | Physical-device onboarding and privacy checks; no unsupported microphone or lifecycle claim. Do not create if the preceding conditional PR is not accepted. |
| Conditional iOS 5 | `mobile-ios-05-release` at `~/.worktrees/ashutoshpw/openwhispr/mobile-ios-05-release` | Starts from `mobile-ios-04-onboarding`; targets it | iOS release hardening, signing with existing entitlements, review disclosures, and supported-device release evidence. | iOS build/release checks and physical-device matrix. No iOS release while keyboard-initiated recording is unsupported or lifecycle behavior is unproven. |

### Remote branch and worktree protocol

No remote branch is assumed to exist during this planning pass. At implementation time, after a predecessor's intended commit is accepted, publish the new branch from that exact predecessor SHA, fetch it, verify the remote ref, and then create the worktree tracking the same remote branch:

```sh
git push origin <accepted-predecessor-sha>:refs/heads/<branch-name>
git fetch origin <branch-name>
git worktree add ~/.worktrees/ashutoshpw/openwhispr/<branch-name> --track -b <branch-name> origin/<branch-name>
```

For example, the first implementation worktree uses `mobile-02-android-feasibility` only after `origin/mobile-02-android-feasibility` has been seeded and verified. Do not create a worktree from `origin/<predecessor>` under the new branch name, and do not use a detached worktree. Each Android-stack PR targets its immediate predecessor. The iOS evidence PR targets `mobile-01-plan` and is not merged into the Android chain; conditional iOS PRs target the preceding branch in their own chain.

When a predecessor merges or its base is intentionally rebased, maintain the stack before starting the next PR: fetch the updated remote refs, record the exact old and new predecessor SHAs, rebase the next branch with `git rebase --onto <new-predecessor-sha> <old-predecessor-sha> <branch-name>`, retarget the PR to the immediate predecessor, and rerun every affected check. Use `git push --force-with-lease` only for a branch owned by this work and only after verifying the expected remote tip; never rewrite another agent's or an accepted shared branch.

## Feasibility gates

### Android: preserve the current keyboard

An ordinary app cannot use the current third-party keyboard's `InputConnection`. An `InputMethodService` would become the keyboard and therefore fails the frozen requirement. The spike must establish whether the agreed target apps can be handled by a native overlay plus a permitted insertion mechanism, likely accessibility-node actions where supported, with explicit limits for secure, noneditable, or hostile fields. Overlay visibility must respond to editable focus and keyboard show/hide state; tapping the overlay alone is not evidence of the required behavior.

Android's Accessibility API is not blanket-prohibited for non-disability apps, but its use requires clear user disclosure, consent, a narrowly described purpose, and a Google Play policy suitability review. The implementation must not hide accessibility enablement or claim arbitrary-app insertion before device evidence exists. Overlay permission, microphone permission, foreground-service rules, battery behavior, and service lifecycle all require physical-device validation.

### iOS: direct extension recording is restricted; companion-session feasibility is conditional

Apple's Custom Keyboard App Extension Programming Guide states:

> “Custom keyboards, like all app extensions in iOS 8.0, have no access to the device microphone, so dictation input is not possible.”

Open access can enable network access and a shared container; it does not by itself grant microphone access. The feasibility branch may therefore test a containing-app-owned audio session activated by one permitted navigation once per session and controlled by keyboard controls, with no app switch for each dictation. Treat session expiry, termination, and reboot as session boundaries requiring explicit reactivation. An interruption requires reactivation only when the active session cannot safely recover; test recovery otherwise. Ending or cancelling a dictation, or reaching the 120-second per-dictation cap, should leave the activation session usable when the OS permits. Do not write a Swift keyboard implementation that implies it can record, and make no promise that recording persists across a session boundary. A future iOS PR may be proposed only after reproducible physical-device evidence and reviewer-policy assessment unblock the conditional stack.

### Backend credentials and privacy contracts

The mobile client must verify the server contracts before making product claims about credentials or privacy. The auth/cloud PR must establish how managed-account credentials are issued, refreshed, revoked, scoped, and redacted; how BYOK values are transmitted and whether the server ever stores them; which provider/model routes are supported; and whether audio, transcripts, logs, history sync, deletion, and retention are controlled server-side. Until those facts are confirmed, keep the product defaults (local transcript history, no audio retention or sync requested by default) while labeling backend behavior as unverified. Never promise server-side deletion, zero retention, or secret non-persistence from client behavior alone.

## Validation matrix

- **Repository:** preserve Node 24 and the existing npm lockfile. Run the applicable `npm run format:check`, `npm run typecheck`, `npm run quality-check`, `npm run i18n:check`, `npm test`, and high-severity audit gates; use the repository's existing CI environment variables where required.
- **Shared core:** pure unit tests for route resolution, provider/BYOK policy, auth expiration, cancellation, focus/target decisions, PCM conversion, and error mapping. Test the mobile transport without a browser or Electron global.
- **Android:** Gradle unit/instrumented tests plus physical Android 10+ devices. Exercise at least one existing third-party keyboard, representative editable apps, secure fields, permission denial, focus-triggered overlay show/hide, keyboard visibility transitions, target focus changes, network loss, and service process death. A verified target inserts automatically; only an uncertain or changed target uses explicit recovery.
- **React Native:** TypeScript/lint/unit checks and native debug/release builds after scaffolding exists. Keep the native service path testable without starting the RN packager.
- **iOS:** feasibility evidence on a physical device and the intended SDK. Simulator success is insufficient. Test one activation per session, no per-dictation switch, companion-session controls, session expiry, termination/reboot, interruption recovery versus explicit reactivation, per-dictation cancellation/120-second cap behavior, and policy review. No conditional release gate can pass while the required flow remains unsupported.
- **Privacy/security:** inspect persisted files and logs for audio, transcript, access tokens, and BYOK secrets; verify local-history and no-audio-retention defaults; document any backend behavior that has not been confirmed.

## Official references

- [Apple: Custom Keyboard App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html) — custom-keyboard sandbox limits, open access, and the documented microphone/dictation restriction.
- [Apple: Creating a Custom Keyboard](https://developer.apple.com/documentation/uikit/keyboards_and_input/creating_a_custom_keyboard) — current custom-keyboard setup and `UIInputViewController` entry point.
- [Apple: App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) — review obligations for networked keyboard extensions and user data.
- [Android: `InputMethodService`](https://developer.android.com/reference/android/inputmethodservice/InputMethodService) — confirms that an IME is the keyboard service and is incompatible with preserving another active keyboard.
- [Android: `AccessibilityService`](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService) — active-window and node-action APIs to validate in the spike.
- [Android: `SYSTEM_ALERT_WINDOW`](https://developer.android.com/reference/android/Manifest.permission#SYSTEM_ALERT_WINDOW) — overlay permission requirements.
- [Android: Foreground service types, microphone](https://developer.android.com/develop/background-work/services/fgs/service-types#microphone) — microphone foreground-service constraints.
- [Google Play: Accessibility API policy](https://support.google.com/googleplay/android-developer/answer/9888379) — disclosure, consent, and policy suitability requirements.
- [React Native: Turbo Native Modules](https://reactnative.dev/docs/turbo-native-modules-introduction) — current typed native-module boundary reference for the foundation work.

## Documentation PR checks

- Confirm this file is under `docs/superpowers/plans/` and all referenced repository paths exist before implementation begins.
- Check Markdown links and `git diff --check` for this file.
- This PR contains documentation only; native files and platform projects remain absent until the feasibility gates and predecessor branches are accepted.
