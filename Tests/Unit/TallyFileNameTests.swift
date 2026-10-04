import Foundation
import Testing
@testable import Tally

nonisolated struct TallyFileNameTests {
    @Test func outerWhitespaceAndOptionalExtensionAreNormalized() throws {
        #expect(try TallyFileName.baseName(from: " \t\n Household Budget \r\n ") == "Household Budget")
        #expect(try TallyFileName.fileName(from: "\u{2003}Household Budget.tAlLy\u{00A0}") == "Household Budget.tally")
        #expect(try TallyFileName.baseName(from: "Household Budget.TALLY") == "Household Budget")
        #expect(try TallyFileName.fileName(from: "Household Budget") == "Household Budget.tally")
    }

    @Test(arguments: ["Budget.2026", "Budget.final.csv", "家計 費用", "Café  Budget", "Cafe\u{301} Budget", "Family 👨‍👩‍👧‍👦", "بودجه\u{200C}سال", ".Household", "Budget..2026", "Budget."])
    func validUnicodeSpacesAndDotsArePreserved(_ name: String) throws {
        #expect(try TallyFileName.baseName(from: name) == name)
        #expect(try TallyFileName.fileName(from: name) == name + ".tally")
    }

    @Test func onlyOneTallyExtensionIsRemoved() throws {
        #expect(try TallyFileName.baseName(from: "Budget.tally.tally") == "Budget.tally")
        #expect(try TallyFileName.fileName(from: "Budget.TALLY.tAlLy") == "Budget.TALLY.tally")
        #expect(try TallyFileName.fileName(from: "Budget .tally") == "Budget .tally")
        #expect(try TallyFileName.fileName(from: "Budget.2026.TALLY") == "Budget.2026.tally")
    }

    @Test(arguments: ["", " \t\n ", ".tally", ".TALLY", " \n.tally\t "])
    func emptyNamesAndExtensionOnlyNamesAreRejected(_ input: String) {
        #expect(throws: TallyFileNameError.emptyName) { try TallyFileName.baseName(from: input) }
        #expect(throws: TallyFileNameError.emptyName) { try TallyFileName.fileName(from: input) }
    }

    @Test(arguments: [".", "..", " . ", " .. ", "..tally", "...TALLY"])
    func reservedPathNamesAreRejected(_ input: String) {
        #expect(throws: TallyFileNameError.reservedName) { try TallyFileName.baseName(from: input) }
        #expect(throws: TallyFileNameError.reservedName) { try TallyFileName.fileName(from: input) }
    }

    @Test(arguments: ["../Budget", "Budget/2026", "/Budget", "Budget/", "Budget:2026", "file:Budget.tally"])
    func pathComponentsAreRejected(_ input: String) {
        #expect(throws: TallyFileNameError.pathSeparators) { try TallyFileName.fileName(from: input) }
    }

    @Test(arguments: ["Cash\u{0}Flow", "Cash\nFlow", "Cash\rFlow", "Cash\tFlow", "Cash\u{7F}Flow", "Cash\u{85}Flow", "Cash\u{2028}Flow", "Cash\u{2029}Flow", "\u{1}Budget", "Budget\u{7F}"])
    func embeddedNewlinesAndControlCharactersAreRejected(_ input: String) {
        #expect(throws: TallyFileNameError.controlCharacters) { try TallyFileName.fileName(from: input) }
    }

    @Test func byteLimitIncludesTheAddedExtension() throws {
        let longest = String(repeating: "a", count: 249)
        let fileName = try TallyFileName.fileName(from: longest)
        #expect(fileName.utf8.count == 255)
        #expect(try TallyFileName.fileName(from: longest + ".TALLY") == fileName)
        #expect(throws: TallyFileNameError.tooLong) { try TallyFileName.baseName(from: longest + "a") }
        #expect(throws: TallyFileNameError.tooLong) { try TallyFileName.fileName(from: longest + "a.tally") }
    }

    @Test func byteLimitUsesUTF8RatherThanCharacterCount() throws {
        let threeByteName = String(repeating: "費", count: 83)
        #expect(try TallyFileName.fileName(from: threeByteName).utf8.count == 255)
        #expect(throws: TallyFileNameError.tooLong) { try TallyFileName.fileName(from: threeByteName + "a") }

        let emojiName = String(repeating: "🍃", count: 62) + "a"
        #expect(try TallyFileName.fileName(from: emojiName).utf8.count == 255)
        #expect(throws: TallyFileNameError.tooLong) { try TallyFileName.fileName(from: emojiName + "a") }

        let decomposedName = String(repeating: "e\u{301}", count: 83)
        #expect(try TallyFileName.baseName(from: decomposedName) == decomposedName)
        #expect(try TallyFileName.fileName(from: decomposedName).utf8.count == 255)
        #expect(throws: TallyFileNameError.tooLong) { try TallyFileName.fileName(from: decomposedName + "a") }
    }
}
