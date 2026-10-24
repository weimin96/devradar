import AppKit

nonisolated enum ApplicationRunLoop {
    // terminateLater enters AppKit's modal run loop. Main-queue callbacks and
    // default-mode timers alone cannot complete cleanup in that mode.
    static func perform(_ operation: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.default, .modalPanel]) {
            MainActor.assumeIsolated { operation() }
        }
    }
}
