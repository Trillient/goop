#if os(iOS)
import BackgroundTasks
import Foundation

/// Best-effort background fallback for the user-owned self-hosted export.
///
/// A completed strap offload starts an immediate, independent export while the app process is alive. This
/// scheduler covers an export deferred by an unavailable network or an expired background wake. iOS chooses
/// the actual delivery time.
@MainActor
enum SelfHostedPushBackgroundScheduler {
    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".selfhostedpush"
    private static let earliestDelay: TimeInterval = 15 * 60

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "selfHostedPush.enabled") }

    static func register(perform operation: @escaping @MainActor () async -> Bool) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                let succeeded = await operation()
                guard !Task.isCancelled else { return }
                if isEnabled { schedule() }
                completion.finish(success: succeeded)
            }
            task.expirationHandler = {
                worker.cancel()
                if isEnabled { schedule() }
                completion.finish(success: false)
            }
        }
    }

    static func schedule(now: Date = Date()) {
        guard isEnabled else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = now.addingTimeInterval(earliestDelay)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled { schedule() } else { cancel() }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
            task.expirationHandler = nil
        }
    }
}
#endif
