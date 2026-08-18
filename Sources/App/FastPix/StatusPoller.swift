import Foundation

enum StatusPollerError: Error {
    case deadlineExceeded
}

/// Capped exponential backoff to an overall deadline. Schedule and loop are pure (injectable
/// sleep/clock) so tests never sleep.
enum StatusPoller {
    /// 2 → 4 → 8 → 10 → 10 …, truncated so the running sum stays within `deadline`.
    static func delays(initial: Double = 2, cap: Double = 10, deadline: Double = 600) -> AnySequence<Double> {
        AnySequence { () -> AnyIterator<Double> in
            var current = initial
            var elapsed = 0.0

            return AnyIterator {
                let next = min(current, cap)
                guard elapsed + next <= deadline else { return nil }
                elapsed += next
                current = min(current * 2, cap)
                return next
            }
        }
    }

    /// Runs `probe` until `isDone`, sleeping the backoff schedule between attempts; throws
    /// `.deadlineExceeded` once `now()` passes `deadline`.
    static func poll<T>(probe: () async throws -> T,
                        isDone: (T) -> Bool,
                        sleep: (Double) async throws -> Void,
                        now: () -> Double,
                        deadline: Double = 600) async throws -> T {
        let start = now()

        for delay in delays(deadline: deadline) {
            let value = try await probe()
            if isDone(value) { return value }
            if now() - start >= deadline { throw StatusPollerError.deadlineExceeded }
            try await sleep(delay)
        }

        let value = try await probe()
        if isDone(value) { return value }
        throw StatusPollerError.deadlineExceeded
    }
}
