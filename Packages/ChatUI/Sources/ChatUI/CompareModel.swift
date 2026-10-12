import Foundation
import Observation
import HybridRouterKit

/// Runs one prompt on every route side by side, each in a fresh session.
@MainActor
@Observable
public final class CompareModel {
    public struct Column: Identifiable, Sendable {
        public let route: Route
        public var content: TurnContent = .text("")
        public var metrics: StepMetrics?
        /// Why this route didn't answer: unavailable, kept private, or an error.
        public var note: String?
        public var isRunning = false

        public var id: Route { route }
    }

    public var prompt = ""
    public private(set) var columns: [Column] = Route.allCases.map { Column(route: $0) }
    public private(set) var isRunning = false

    @ObservationIgnored private let makeSession: @MainActor () -> RoutedSession
    @ObservationIgnored private let privacyGuard = PrivacyGuard()

    /// - Parameter makeSession: a fresh session with the app's providers, one per column.
    public init(makeSession: @escaping @MainActor () -> RoutedSession) {
        self.makeSession = makeSession
    }

    public var canRun: Bool {
        !isRunning && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func run() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        columns = Route.allCases.map { Column(route: $0) }
        let privacy = privacyGuard.assess(text)

        // Each route answers concurrently. (A task group here trips a Swift 6.4 isolation
        // checker bug, so these are main-actor tasks awaited together.)
        var answers: [Task<Void, Never>] = []
        for (index, route) in Route.allCases.enumerated() {
            if route == .claude, let privacy {
                columns[index].note = "Kept private: \(privacy.label)"
                continue
            }
            let session = makeSession()
            if case .unavailable(let reason) = session.availability(of: route) {
                columns[index].note = reason
                continue
            }
            columns[index].isRunning = true
            answers.append(Task {
                await answer(text, on: route, at: index, in: session, isPrivate: privacy != nil)
            })
        }
        // Closing compare mode cancels the run, so in-flight (and paid) replies stop too.
        await withTaskCancellationHandler {
            for answer in answers {
                await answer.value
            }
        } onCancel: {
            answers.forEach { $0.cancel() }
        }
    }

    private func answer(_ text: String, on route: Route, at index: Int, in session: RoutedSession, isPrivate: Bool) async {
        do {
            var throttle = StreamThrottle()
            let result = try await session.respond(to: text, decision: .forced(route), isPrivate: isPrivate) { [weak self] partial in
                if throttle.shouldUpdate() {
                    self?.columns[index].content = partial
                }
            }
            columns[index].content = result.content
            columns[index].metrics = result.metrics
        } catch {
            columns[index].note = "Couldn't answer (\(FailureCause(error).label))"
        }
        columns[index].isRunning = false
    }
}
