import CoreFoundation
import Foundation

/// Darwin notifications are process-to-process signals only. Consumers must read
/// and validate the versioned App Group command after receiving one.
public final class AppGroupSignalObserver {
    private let queue: OperationQueue
    private let handler: () -> Void
    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private let name = CFNotificationName(rawValue: AppGroupConstants.signalName as CFString)

    public init(queue: OperationQueue = .main, handler: @escaping () -> Void) {
        self.queue = queue
        self.handler = handler
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let signalObserver = Unmanaged<AppGroupSignalObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                signalObserver.queue.addOperation(signalObserver.handler)
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, name, nil)
    }

    public static func post() {
        let name = CFNotificationName(rawValue: AppGroupConstants.signalName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }
}
