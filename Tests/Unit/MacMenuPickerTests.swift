#if os(macOS)
import AppKit
import Testing
@testable import Tally

@MainActor
struct MacMenuPickerTests {
    @Test func closedCategoryControlShrinksForOtherWithoutRemovingChoices() {
        let button = AccessiblePopUpButton(frame: .zero, pullsDown: false)
        let titles = ExpenseCategory.allCases.filter { $0 != .income }.map(\.title)
        button.addItems(withTitles: titles)
        button.selectItem(withTitle: "Subscriptions")
        let longSize = button.intrinsicContentSize
        button.selectItem(withTitle: "Other")
        let shortSize = button.intrinsicContentSize

        #expect(shortSize.width < longSize.width - 25)
        #expect(shortSize.height == longSize.height)
        #expect(button.itemTitles == titles)
        #expect(button.titleOfSelectedItem == "Other")
    }

    @Test func closedFrequencyTracksSelectionAndKeepsNativeChrome() {
        let button = AccessiblePopUpButton(frame: .zero, pullsDown: false)
        button.addItems(withTitles: Recurrence.allCases.map(\.title))
        button.selectItem(withTitle: "Every two weeks")
        let longSize = button.intrinsicContentSize
        button.selectItem(withTitle: "Monthly")
        let monthlySize = button.intrinsicContentSize
        let textWidth = ("Monthly" as NSString).size(withAttributes: [.font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width

        #expect(monthlySize.width < longSize.width - 25)
        #expect(monthlySize.width >= textWidth + 15)
        #expect(monthlySize.width < textWidth + 60)
        button.selectItem(withTitle: "Every two weeks")
        #expect(button.intrinsicContentSize == longSize)
    }
}
#endif
