import Foundation

/// Preserves the order of user requests across asynchronous reveal, close, and open operations.
nonisolated struct MobileOpenRequestOrder {
    struct Ticket: Equatable, Sendable {
        let url: URL
        let generation: UInt64
    }

    private var generation: UInt64 = 0

    mutating func request(_ url: URL) -> Ticket {
        generation &+= 1
        return Ticket(url: url, generation: generation)
    }

    /// Cancels pending opens when the user chooses another browser action.
    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation
    }
}
