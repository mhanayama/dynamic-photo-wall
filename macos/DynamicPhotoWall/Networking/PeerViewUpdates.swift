import Foundation

// Keep packet bursts from rebuilding SwiftUI forms for every network message.
@MainActor final class PNViewUpdates {
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private let delay: Duration
    init(delay: Duration = .milliseconds(100)) { self.delay = delay }
    func request(_ update: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        let token = generation, delay = delay
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, generation == token else { return }
            pending = nil
            update()
        }
    }
    func cancel() { generation = UUID(); pending?.cancel(); pending = nil }
}
