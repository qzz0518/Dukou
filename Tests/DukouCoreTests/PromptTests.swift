import DukouCore
import Foundation
import XCTest

/// 附加 Prompt: what gets pasted, in what order, and how the library behaves.
final class PromptTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/tmp/聊天记录 a.zip")
    private let b = URL(fileURLWithPath: "/tmp/b.zip")

    // MARK: - The plan

    func testNoPromptMeansJustTheFiles() {
        XCTAssertEqual(PastePlan.make(urls: [a], pathOnly: false, prompt: nil), [.files([a])])
        XCTAssertEqual(PastePlan.make(urls: [a], pathOnly: false, prompt: "  \n"), [.files([a])])
        XCTAssertEqual(PastePlan.make(urls: [a], pathOnly: true, prompt: nil), [.text("'/tmp/聊天记录 a.zip' ")])
    }

    /// A chat app takes the files from a pasteboard that offers both, so the
    /// prompt has to be its own ⌘V — and it is the first one.
    func testAPromptBeforeTheFilesIsTwoPastes() {
        XCTAssertEqual(
            PastePlan.make(urls: [a, b], pathOnly: false, prompt: "总结一下"),
            [.text("总结一下"), .files([a, b])]
        )
        XCTAssertEqual(
            PastePlan.make(urls: [a, b], pathOnly: false, prompt: "总结一下\n"),
            [.text("总结一下"), .files([a, b])]
        )
    }

    /// A terminal gets one line, and a newline in it would be Return.
    func testAPromptForATerminalIsOneLine() {
        XCTAssertEqual(
            PastePlan.make(urls: [a], pathOnly: true, prompt: "读一下\n再总结  "),
            [.text("读一下 再总结 '/tmp/聊天记录 a.zip' ")]
        )
        XCTAssertEqual(
            PastePlan.make(urls: [a, b], pathOnly: true, prompt: "总结"),
            [.text("总结 '/tmp/聊天记录 a.zip' '/tmp/b.zip' ")]
        )
    }

    func testAManualPasteGetsTheFilesNotTheBarePrompt() {
        let plan = PastePlan.make(urls: [a], pathOnly: false, prompt: "p")
        XCTAssertEqual(PastePlan.manualPayload(plan), .files([a]))
        let line = PastePlan.make(urls: [a], pathOnly: true, prompt: "p")
        XCTAssertEqual(PastePlan.manualPayload(line), line.first)
        XCTAssertNil(PastePlan.manualPayload([]))
    }

    // MARK: - The library

    func testTheDefaultIsOnePromptSelectedWithBothSwitchesOff() {
        let settings = PromptSettings.makeDefault(text: "请总结")
        XCTAssertEqual(settings.prompts.count, 1)
        XCTAssertEqual(settings.selected?.text, "请总结")
        XCTAssertNil(settings.attachment(for: .forward))
        XCTAssertNil(settings.attachment(for: .wechat))
        XCTAssertNil(settings.attachment(for: .moments))
    }

    func testEachSurfaceHasItsOwnSwitchOverTheSharedSelection() {
        var settings = PromptSettings.makeDefault(text: "请总结")
        settings.attachToWeChat = true
        XCTAssertNil(settings.attachment(for: .forward))
        XCTAssertEqual(settings.attachment(for: .wechat)?.text, "请总结")
        XCTAssertNil(settings.attachment(for: .moments))
        settings.attachToMoments = true
        XCTAssertEqual(settings.attachment(for: .moments)?.text, "请总结")
        // A blank prompt is no prompt, whatever the switch says.
        settings.prompts[0].text = "   "
        XCTAssertNil(settings.attachment(for: .wechat))
        XCTAssertNil(settings.attachment(for: .moments))
    }

    func testTheLibraryHoldsThreeAndAddingSelectsTheNewOne() {
        var settings = PromptSettings.makeDefault(text: "1")
        XCTAssertTrue(settings.add(AttachedPrompt(text: "2")))
        XCTAssertEqual(settings.selected?.text, "2")
        XCTAssertTrue(settings.add(AttachedPrompt(text: "3")))
        XCTAssertFalse(settings.canAdd)
        XCTAssertFalse(settings.add(AttachedPrompt(text: "4")))
        XCTAssertEqual(settings.prompts.count, 3)
    }

    func testRemovingTheSelectedPromptFallsBackToTheFirst() {
        var settings = PromptSettings.makeDefault(text: "1")
        settings.add(AttachedPrompt(text: "2"))
        let second = settings.selectedID!
        settings.remove(id: second)
        XCTAssertEqual(settings.selected?.text, "1")
        settings.remove(id: settings.selectedID!)
        XCTAssertTrue(settings.prompts.isEmpty)
        XCTAssertNil(settings.selected)
        XCTAssertNil(settings.attachment(for: .forward))
    }

    /// A blob from an older build — one that named every prompt and stored a
    /// position — still decodes; those two keys are simply not read. So does a
    /// blob with more than three prompts, or a selection pointing nowhere.
    func testDecodingClampsRepairsTheSelectionAndIgnoresRetiredKeys() throws {
        let json = """
        {"prompts":[{"id":"11111111-1111-1111-1111-111111111111","title":"a","text":"1"},
                    {"id":"22222222-2222-2222-2222-222222222222","title":"b","text":"2"},
                    {"id":"33333333-3333-3333-3333-333333333333","title":"c","text":"3"},
                    {"id":"44444444-4444-4444-4444-444444444444","title":"d","text":"4"}],
         "selectedID":"99999999-9999-9999-9999-999999999999","position":"after","attachToForwards":true}
        """
        let settings = try JSONDecoder().decode(PromptSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.prompts.map(\.text), ["1", "2", "3"])
        XCTAssertEqual(settings.selected?.text, "1")
        XCTAssertEqual(settings.attachment(for: .forward)?.text, "1")
        XCTAssertFalse(settings.attachToMoments)
    }
}
