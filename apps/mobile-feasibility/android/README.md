# OpenWhispr Android feasibility spike

This is a standalone Kotlin Android spike for the frozen Android requirement:
the user's existing third-party keyboard remains selected while OpenWhispr shows
a small floating microphone over a supported editable field. It does not contain
a React Native shell, cloud client, account flow, or `InputMethodService`.

The spike answers a narrow feasibility question:

1. Can an `AccessibilityService` observe an actually focused plain editable field
   while the current keyboard is visible?
2. Can a `TYPE_APPLICATION_OVERLAY` control remain non-focusable and trigger a
   foreground microphone capture without replacing that keyboard?
3. Can a transcript be inserted safely when the original target, text, and
   selection are unchanged?

The service is deliberately conservative. It only exposes known plain text
editor classes with `ACTION_SET_TEXT`; password fields, rich/web/Compose/unknown
editors, changed focus, changed text, and changed selection are rejected. Device
evidence must expand this table one app and field at a time.

## Selected toolchain

| Component | Version | Evidence/source |
| --- | --- | --- |
| JDK | Temurin 17.0.20.1 | Adoptium release; SHA-256 `3808d1d15e3ec6bd5b84057fb5d84c33d8a1536a258146bcea2e603fc726e08e` |
| Android Gradle Plugin | 8.7.2 | [Official AGP 8.7 compatibility notes](https://developer.android.com/build/releases/agp-8-7-0-release-notes) list API 35, Gradle 8.9, and JDK 17 |
| Gradle | 8.9 | Wrapper distribution |
| Kotlin Gradle Plugin | 2.1.21 | `org.jetbrains.kotlin.android` plugin in `build.gradle.kts` |
| Android command-line tools | 22.0 (`15859902`) | Official Android Developers download; SHA-256 `4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583` |
| Android SDK | compile/target 35, min 29 | `platforms;android-35` and `build-tools;35.0.1` |

The local verification cache used for this spike is
`/home/ashutosh/.cache/openwhispr-mobile/android-tools`. It is not required to
be installed globally and no shell profile is modified. Set the variables below
per command or per terminal session when building locally:

```sh
export OPENWHISPR_ANDROID_CACHE=/home/ashutosh/.cache/openwhispr-mobile/android-tools
export JAVA_HOME="$OPENWHISPR_ANDROID_CACHE/jdk/jdk-17.0.20.1+1"
export ANDROID_SDK_ROOT="$OPENWHISPR_ANDROID_CACHE/android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export PATH="$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
```

The Gradle wrapper downloads Gradle 8.9 into the normal user Gradle cache. The
wrapper's official distribution SHA-256 is
`d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab`.

## Build and pure tests

From this directory:

```sh
./gradlew testDebugUnitTest assembleDebug
```

The build does not start an emulator. The unit tests in `app/src/test` cover
prefix/suffix splicing, cursor and selection replacement, target
identity/text/selection changes, password fields, unsupported editors, blank
transcripts, cancellation before late completion, deadline completion, and stale
generation cleanup (11 tests total).

The debug APK is written to
`app/build/outputs/apk/debug/app-debug.apk`. The host used to prepare this spike
has no Android device, emulator, or `adb` target, so physical-device acceptance
remains pending.

## Device setup

Install the debug APK on a physical Android 10+ device and use the device
Settings UI to:

1. Enable **OpenWhispr editable target capture** under Accessibility. The app
   shows the purpose and does not hide this enablement behind an unrelated flow.
2. Allow **Display over other apps** for the floating microphone.
3. Allow the microphone permission. Android 13+ notification permission may also
   be needed for a visible foreground-service notification.
4. Leave an existing third-party keyboard selected. This spike never registers
   an input method and never calls `InputConnection`.
5. Optionally enable **Deterministic fixture transcript (explicit test mode)**
   in the app. It is off by default and is the only mode that performs local
   insertion; the inserted text is visibly prefixed with
   `[OpenWhispr fixture transcript]`.

The foreground microphone service is started only by tapping the visible overlay
after an editable target and the keyboard have both been observed. A long press
on the overlay, or the **Cancel** action in the foreground notification, cancels
capture and clears the in-memory PCM buffer. The notification's **Stop** action
and a normal overlay tap stop capture; with fixture mode enabled the service then
attempts one verified insertion. The notification actions keep explicit control
available if focus changes and the overlay hides.

If the focused editable target or keyboard disappears while recording, the
accessibility service cancels the run and wipes the captured PCM. It does not keep
capturing invisibly after the overlay is hidden.
With fixture mode disabled, the microphone is captured for the spike and then
discarded because no cloud transport is included here.

## Acceptance matrix

Record the device model, Android version, keyboard, app/field, result, and any
failure reason for each row. Do not record field contents, transcripts, audio,
tokens, or screenshots containing private text in logs or test reports.

| Scenario | Expected result | Evidence | Status |
| --- | --- | --- | --- |
| Accessibility disclosure and consent | User can identify and explicitly enable the service | Settings + app copy | Pending physical device |
| Existing third-party keyboard remains selected | Current keyboard is still shown; no IME switch | Settings and target app | Pending physical device |
| Editable focus with keyboard visible | Overlay appears only after both states are observed | Focus/keyboard transition recording | Pending physical device |
| Focus lost or keyboard hidden | Overlay disappears | Focus/keyboard transition recording | Pending physical device |
| Overlay interaction | Overlay is touchable but cannot take text focus | Target cursor remains in the existing editor | Pending physical device |
| Microphone permission denied | Capture does not start; service reports a generic error | Permission denial run | Pending physical device |
| Overlay permission denied | Overlay cannot appear and no capture starts | Permission denial run | Pending physical device |
| Tap-to-start and tap-to-stop | Foreground microphone notification appears and capture ends | Notification + status, with no audio dump | Pending physical device |
| Long press cancellation | Capture ends and raw in-memory audio is cleared | Status + process inspection | Pending physical device |
| Explicit fixture insertion in plain `EditText` | Prefix and suffix survive; fixture label is inserted at the original selection | Target app result | Pending physical device |
| Selection/text changed during capture | No insertion into the changed target | Target app result | Pending physical device |
| Focus changed to another editable field | No insertion into the new field; explicit recovery is required | Two-field run | Pending physical device |
| Password field | Overlay/insertion is rejected | Password field run | Pending physical device |
| Rich, WebView, Compose, or unknown editor | Insertion is rejected until separately approved | Representative app runs | Pending physical device |
| Service process death/restart | No stale target or stale audio is reused; user must re-enable/retry | Force-stop/restart run | Pending physical device |
| Hard maximum | Capture stops at 120 seconds and fixture insertion remains a single dictation | Timed run | Pending physical device |
| OEM battery/background policy | Visible-accessibility launch and foreground service continue or produce a documented limitation | OEM-specific run | Pending physical device |

The rows are feasibility evidence, not a claim of arbitrary-app support. A
production path must repeat this matrix on the actual target devices and obtain
a separate Android Accessibility API / Google Play policy review before release.

## Runtime and policy boundaries

- `RecordingService` is `exported="false"`, has no intent-filter, and has no
  external command surface. The accessibility service is exported only because
  Android binds platform accessibility services through
  `BIND_ACCESSIBILITY_SERVICE`; that permission is required and its commands
  are not exposed to other apps.
- `FOREGROUND_SERVICE_MICROPHONE` and `RECORD_AUDIO` are declared, but build
  success is not runtime proof. Android 12+ foreground-service launch rules,
  Android 14 microphone prerequisites, notification behavior, and OEM policies
  require physical-device validation. The visible overlay tap is the intended
  user-initiated launch path.
- Accessibility access can expose sensitive screen content. The disclosure,
  explicit consent, narrow purpose, and strict target limits in this spike are
  required for review; they do not establish Google Play policy approval.
- No clipboard, transcript history, audio file, account token, BYOK key, or
  Electron/React Native bridge is used. Text and PCM exist only in short-lived
  process memory and are cleared after cancellation or completion.
