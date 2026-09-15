# OpenWhispr iOS feasibility prototype

Status: source prototype only. The required keyboard initiated recording flow is
blocked until it is demonstrated on a physical iOS device and reviewed against
Apple's keyboard and background audio policies. A successful compile or reducer
test does not establish device feasibility.

## What this prototype tests

The containing app owns `AVAudioSession` and an `AVAudioEngine`. A user must
activate one recording session in the app. The app keeps the audio session and
engine active for that lease so background behavior can be observed while the
keyboard is visible. The app shows a disclosure that the microphone remains
active until **End Session** is pressed; frames outside an active dictation are
discarded and no audio is persisted.

The custom keyboard has no microphone implementation. Its microphone button
writes a versioned command to an App Group queue file under a cross-process lock
and posts a payloadless Darwin notification. Queue and insertion-fence updates
reread the file while holding that lock and replace it atomically; persistence
errors fail closed instead of being treated as an empty queue or an available
fence. The host rereads and validates the command, then writes state back to the
App Group. Darwin notifications are signals only: they do not carry a trusted
payload and they do not guarantee that a suspended host process wakes.

The command protocol contains a schema version, nonce, session ID, dictation ID,
optional result ID and insertion-fence nonce, and issue time. Commands are
queued in the App Group and consumed in order, so a rapid stop/cancel sequence
cannot overwrite an earlier command. The reducer ignores a duplicate nonce and
rejects stale commands, wrong sessions, wrong dictations, and mismatched result
acknowledgements. The host heartbeat and session lease make a dead or suspended
host fail closed instead of looking ready forever.

Ending or cancelling a dictation returns the activation session to `ready` when
the host is still alive. The host ends the current dictation at 120 seconds and
keeps the activation session available. Host launch, explicit expiry, process
termination, reboot, or an unrecoverable audio interruption requires a new
activation. The prototype does not claim that an iOS process survives any of
those boundaries.

The transcriber is deterministic fixture code. Every output is prefixed with
`[Fixture transcription]` and is unsuitable as provider or product evidence.

## Keyboard safety behavior

The keyboard includes basic letter keys, space, return, backspace, and a next
keyboard control so the feasibility flow can be exercised without another
keyboard dependency. The microphone control is at the top right.

Before starting a dictation, the keyboard captures the current document
identifier, context, and selection. It refuses to start when all of that
evidence is empty and therefore ambiguous. During recording it cancels when the
editor reports a text change or when the extension disappears. Before insertion
it compares the current identity, context, and selection with the captured
target. A changed or unavailable target never receives a silent insertion; the
user must explicitly tap **Insert fixture result** after revalidating the target.
A result from a prior extension instance is likewise shown as an explicit
recovery action.

Before calling \`insertText\`, the keyboard durably records an App Group insertion
fence as \`claimed\`. The fence is marked \`inserted\` only after the call returns,
and the acknowledgement includes the claim nonce. If the keyboard dies between
those operations, the next instance sees the claimed fence and will not insert
automatically. It offers copy-and-acknowledge manual recovery; an inserted fence
can only be acknowledged, never inserted again.

## Build and test

The project is generated from [`project.yml`](project.yml) with XcodeGen. The
generated `.xcodeproj` is ignored and is never hand-authored. On a Mac with
XcodeGen installed:

```sh
xcodegen generate --spec project.yml
swift test --package-path .
xcodebuild \
  -project OpenWhisprIOSFeasibility.xcodeproj \
  -scheme OpenWhisprFeasibility \
  -sdk iphoneos \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

The dedicated GitHub workflow pins `macos-15`, selects Xcode 16.4, verifies the
SHA-256 of XcodeGen 2.46.0, runs the pure Foundation tests on macOS, generates
the project, and performs an unsigned `iphoneos` SDK build. It does not launch
Simulator, invoke `simctl`, run a simulator destination, sign, install, deploy,
or submit an artifact.

## Evidence matrix

| Evidence | Current status | What it proves |
| --- | --- | --- |
| SwiftPM reducer tests | CI check | Session/cancel/cap/idempotency and context decisions are deterministic. |
| XcodeGen generation | CI check | The checked-in spec can produce both native targets. |
| Unsigned `iphoneos` build | CI check | Host and keyboard sources compile against the selected SDK. |
| Physical iPhone/iPad flow | Pending | One activation, keyboard commands, host heartbeat, insertion, and lifecycle behavior on real OS hardware. |
| Apple policy review | Pending | Whether the companion-owned always-active audio design and open-access keyboard are acceptable for distribution. |
| Signing, installation, deployment, release | Not attempted | This branch intentionally produces no release claim or signed artifact. |

## Physical-device checklist

Run this checklist only on a real, trusted device. Do not substitute a
simulator. Record the device model, iOS version, Xcode version, and exact build
configuration with each result.

1. Install the unsigned or development-signed test build using the authorized
   device workflow, grant microphone access, enable the keyboard, and grant
   open access if required for the App Group.
2. From the keyboard, open OpenWhispr once, activate the session, and return to
   the original app. Confirm the host status reports an active audio engine and
   the microphone disclosure is visible.
3. In an identifiable editable field, start and stop a dictation without
   opening the containing app again. Confirm the inserted text is explicitly
   labeled as fixture output.
4. Change editors or fields during recording. Confirm the keyboard cancels and
   never inserts into the new target. Confirm an ambiguous or changed target
   requires an explicit retry.
5. Cancel a dictation and verify the activation session remains ready. Let a
   dictation reach 120 seconds and verify the cap ends only that dictation.
6. Trigger an audio interruption. Record whether the host recovers without
   reactivation; if it cannot recover, verify that the UI requires reactivation.
7. End the session, expire it, terminate the host, and reboot the device. Each
   boundary must stop trusting the old lease and require explicit activation.
8. Observe whether the host heartbeat continues while the keyboard is in the
   foreground. If it stops, verify the keyboard fails closed and explains that
   the host must be reactivated; do not infer that a Darwin signal woke it.

## References and known limits

- [Apple Custom Keyboard App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [Apple Creating a Custom Keyboard](https://developer.apple.com/documentation/uikit/keyboards_and_input/creating_a_custom_keyboard)
- [Apple App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

Apple documents that custom keyboard extensions have no access to the device
microphone. This prototype therefore keeps all capture code in the containing
app and treats the companion-session approach as conditional evidence work. No
claim of persistent recording, background reliability, provider transcription,
or App Store eligibility should be made from this branch alone.
