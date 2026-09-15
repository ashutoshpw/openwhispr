import SwiftUI

@main
struct OpenWhisprFeasibilityApp: App {
    @StateObject private var controller = HostSessionController()

    var body: some Scene {
        WindowGroup {
            HostView(controller: controller)
                .onOpenURL { _ in
                    controller.noteActivationRequest()
                }
        }
    }
}
