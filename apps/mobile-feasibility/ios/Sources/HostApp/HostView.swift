import SwiftUI

struct HostView: View {
    @ObservedObject var controller: HostSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("OpenWhispr iOS Feasibility")
                    .font(.title2.weight(.semibold))

                Text("This disposable prototype tests one activation per session. The keyboard never records directly.")
                    .foregroundStyle(.secondary)

                GroupBox("Session") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Phase", value: controller.state.phase.rawValue)
                        LabeledContent("Session", value: controller.state.sessionID ?? "none")
                        LabeledContent("Audio engine", value: controller.sessionIsActive ? "active" : "stopped")
                        LabeledContent("Last dictation frames", value: String(controller.capturedFrames))

                        Text(controller.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if let error = controller.state.lastError {
                            Text("Protocol state: \(error)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Button("Activate Recording Session") {
                    controller.activateSession()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.sessionIsActive)

                Button("End Session") {
                    controller.endSession()
                }
                .buttonStyle(.bordered)
                .disabled(!controller.sessionIsActive)

                Button("Expire Session (Device Test)") {
                    controller.expireSessionForTest()
                }
                .buttonStyle(.bordered)
                .disabled(!controller.sessionIsActive)

                Text("Privacy test condition: while activated, iOS keeps the host AVAudioSession and engine active so background behavior can be observed. Samples are discarded outside an active dictation; no audio is persisted. End Session stops the microphone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("After activation, return to the previous app and choose the OpenWhispr Feasibility keyboard. The keyboard sends start/stop commands through the App Group. If the host heartbeat stops, it fails closed and asks for reactivation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }
}
