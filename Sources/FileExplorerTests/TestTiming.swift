import Foundation

/// Deterministic stand-in for `Task.sleep` in timer-based model tests.
/// Sleepers suspend until the test fires them, so assertions about "before
/// the timer" and "after the timer" never race the wall clock on slow CI
/// runners. `@MainActor` classes are implicitly Sendable, so instances can
/// also gate `@Sendable` runner/renderer closures via `wait()`.
@MainActor
final class ManualTimer {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var pendingCount: Int { waiters.count }

    func sleep(_ duration: Duration) async {
        await wait()
    }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Resume the oldest pending sleeper (the first timer armed).
    func fireFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func fireAll() {
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

/// Poll until `condition` holds: first by yielding the main actor (covers
/// same-actor task handoffs), then with short real sleeps (covers detached
/// work like renders). Waiting *for* a condition cannot flake the way fixed
/// sleeps do; the ~30 s bound is only hit when the tested behavior is
/// genuinely broken, and the caller's assertion then reports the failure.
@MainActor
func settle(until condition: () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    for _ in 0..<6_000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Give already-resumed tasks a chance to run to completion before asserting
/// that something did NOT happen.
@MainActor
func drainMainQueue() async {
    for _ in 0..<50 { await Task.yield() }
}
