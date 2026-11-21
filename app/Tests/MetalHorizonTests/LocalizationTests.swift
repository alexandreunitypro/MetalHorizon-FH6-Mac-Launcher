import XCTest
@testable import MetalHorizon

/// The translations in app/Localization: every language has every English text, and keeps the values (%@, %lld) of
/// each one, in the same order, so that a sentence with a name or a count reads right in every language.
final class LocalizationTests: XCTestCase {
    private var localization: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Localization")
    }

    private func values(_ file: URL) -> [String: String] {
        (NSDictionary(contentsOf: file) as? [String: String]) ?? [:]
    }

    /// The values in the order they come in the sentence.
    private func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(lld|@)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
    }

    func testEveryLanguageHasEveryText() throws {
        let english = try JSONDecoder().decode([String].self, from: Data(contentsOf: localization.appendingPathComponent("en-keys.json")))
        XCTAssertGreaterThan(english.count, 150)
        let folders = try FileManager.default.contentsOfDirectory(at: localization, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        XCTAssertGreaterThanOrEqual(folders.count, 33)
        for folder in folders {
            let table = values(folder.appendingPathComponent("Localizable.strings"))
            XCTAssertEqual(table.count, english.count, folder.lastPathComponent)
            for text in english {
                guard let translated = table[text] else {
                    XCTFail("\(folder.lastPathComponent) has no translation of \(text)")
                    continue
                }
                XCTAssertFalse(translated.trimmingCharacters(in: .whitespaces).isEmpty, "\(folder.lastPathComponent): \(text)")
                XCTAssertEqual(placeholders(translated), placeholders(text), "\(folder.lastPathComponent): \(text)")
            }
        }
    }

    /// A text with no translation in the bundle is shown as it is, in English.
    func testUntranslatedTextStaysEnglish() {
        XCTAssertEqual(tr("A sentence that no language has"), "A sentence that no language has")
        XCTAssertEqual(tr("%lld controllers", 3), "3 controllers")
    }
}
