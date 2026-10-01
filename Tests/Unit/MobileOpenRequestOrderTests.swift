import Foundation
import Testing
@testable import Tally

nonisolated struct MobileOpenRequestOrderTests {
    private let a = URL(fileURLWithPath: "/fixture/A.tally")
    private let b = URL(fileURLWithPath: "/fixture/B.tally")
    private let c = URL(fileURLWithPath: "/fixture/C.tally")

    @Test func aNewerRevealWinsWhileThePreviouslyQueuedOpenWaitsForClose() {
        var order = MobileOpenRequestOrder()
        let opening = order.request(a)
        let queuedAfterReveal = order.request(b)
        #expect(!order.isCurrent(opening))
        #expect(order.isCurrent(queuedAfterReveal))

        // B has already been copied out of the pending queue. Closing A then
        // suspends; a newer external request for C begins its slower reveal.
        let revealing = order.request(c)
        // Completing A's close must not re-register B as a new user request.
        #expect(!order.isCurrent(queuedAfterReveal))
        #expect(order.isCurrent(revealing))
        #expect(revealing.url == c)
    }

    @Test func completionOfAnOlderRevealCannotReplaceTheLatestRequest() {
        var order = MobileOpenRequestOrder()
        let slow = order.request(a)
        let fast = order.request(b)
        #expect(order.isCurrent(fast))
        #expect(!order.isCurrent(slow))
        #expect(order.isCurrent(fast))
    }

    @Test func selectingTheSameFileAgainIsStillANewIntent() {
        var order = MobileOpenRequestOrder()
        let first = order.request(a)
        let second = order.request(a)
        #expect(first != second)
        #expect(!order.isCurrent(first))
        #expect(order.isCurrent(second))
    }

    @Test func settingsOrCreationCancelsAQueuedOpenWithoutCreatingAnother() {
        var order = MobileOpenRequestOrder()
        let queued = order.request(a)
        order.invalidate()
        #expect(!order.isCurrent(queued))
        let subsequentSelection = order.request(b)
        #expect(order.isCurrent(subsequentSelection))
        #expect(!order.isCurrent(queued))
    }
}
