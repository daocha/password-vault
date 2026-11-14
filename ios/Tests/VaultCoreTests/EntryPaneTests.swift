import XCTest
@testable import VaultCore

final class EntryPaneTests: XCTestCase {
    func testOpeningAnEntryShowsItsDetails() {
        var pane = EntryPane<String>()
        XCTAssertEqual(pane.presentation, .none)
        XCTAssertTrue(pane.request(.open("a"), unsavedChanges: false))
        XCTAssertEqual(pane.presentation, .detail("a"))
        XCTAssertTrue(pane.request(.open("b"), unsavedChanges: false))
        XCTAssertEqual(pane.presentation, .detail("b"))
        pane.close()
        XCTAssertEqual(pane.presentation, .none)
    }

    func testEditingAnEntryKeepsItsDetailsUnderneath() {
        var pane = EntryPane<String>()
        pane.request(.open("a"), unsavedChanges: false)
        pane.edit("draft")
        XCTAssertEqual(pane.presentation, .detailAndEditor("a"))
        XCTAssertEqual(pane.editor, "draft")
        pane.closeEditor()
        XCTAssertEqual(pane.presentation, .detail("a"), "discarding returns to the details")
        pane.edit("draft")
        pane.saved("a", showDetails: true)
        XCTAssertEqual(pane.presentation, .detail("a"), "saving returns to the details")
    }

    func testEditNeedsAnOpenEntry() {
        var pane = EntryPane<String>()
        pane.edit("draft")
        XCTAssertNil(pane.editor)
    }

    func testNewEntrySavedOpensItsDetailsOnlyOnWideScreens() {
        var wide = EntryPane<String>()
        wide.request(.create("new"), unsavedChanges: false)
        XCTAssertEqual(wide.presentation, .newEditor)
        wide.saved("n", showDetails: true)
        XCTAssertEqual(wide.presentation, .detail("n"))

        var narrow = EntryPane<String>()
        narrow.request(.create("new"), unsavedChanges: false)
        narrow.saved("n", showDetails: false)
        XCTAssertEqual(narrow.presentation, .none, "a narrow screen returns to the list, as before")
    }

    func testUnsavedChangesWaitForDiscardOrKeepEditing() {
        var pane = EntryPane<String>()
        pane.request(.open("a"), unsavedChanges: false)
        pane.edit("draft")
        XCTAssertFalse(pane.request(.open("b"), unsavedChanges: true))
        XCTAssertEqual(pane.presentation, .detailAndEditor("a"), "nothing changes until the person decides")
        XCTAssertNotNil(pane.pending)
        pane.keepEditing()
        XCTAssertNil(pane.pending)
        XCTAssertEqual(pane.editor, "draft")

        XCTAssertFalse(pane.request(.create("new"), unsavedChanges: true))
        pane.discardChanges()
        XCTAssertEqual(pane.presentation, .newEditor)
        XCTAssertEqual(pane.editor, "new")

        XCTAssertFalse(pane.request(.open("b"), unsavedChanges: true))
        pane.discardChanges()
        XCTAssertEqual(pane.presentation, .detail("b"))
        XCTAssertNil(pane.editor)
    }

    func testAnUntouchedEditorGivesWayWithoutAsking() {
        var pane = EntryPane<String>()
        pane.request(.open("a"), unsavedChanges: false)
        pane.edit("draft")
        XCTAssertTrue(pane.request(.open("b"), unsavedChanges: false))
        XCTAssertEqual(pane.presentation, .detail("b"))
    }

    func testTappingTheOpenEntryAgainChangesNothing() {
        var pane = EntryPane<String>()
        pane.request(.open("a"), unsavedChanges: false)
        pane.edit("draft")
        XCTAssertTrue(pane.request(.open("a"), unsavedChanges: true))
        XCTAssertNil(pane.pending)
        XCTAssertEqual(pane.presentation, .detailAndEditor("a"))
        XCTAssertEqual(pane.editor, "draft")
    }

    func testDeletedEntryClosesButANewEditorStays() {
        var pane = EntryPane<String>()
        pane.request(.open("a"), unsavedChanges: false)
        pane.keepOnly(["a", "b"])
        XCTAssertEqual(pane.presentation, .detail("a"))
        pane.keepOnly(["b"])
        XCTAssertEqual(pane.presentation, .none)

        pane.request(.create("new"), unsavedChanges: false)
        pane.keepOnly([])
        XCTAssertEqual(pane.presentation, .newEditor)
    }

    func testTotpFormReadsTheRecordAndNoticesChanges() throws {
        let account = try TotpAccount(secret: Data([1, 2, 3, 4, 5]), issuer: "Example", account: "me@example.com", algorithm: "SHA256", digits: 8, period: 60)
        var record = account.record(); record.name = "Example"; record.favorite = true
        record.fields.append(VaultField(kind: .note, label: "Notes", value: "backup codes in the safe"))
        let original = TotpForm(record: record)
        XCTAssertEqual(original.name, "Example")
        XCTAssertEqual(original.account, "me@example.com")
        XCTAssertEqual(original.key, account.secretBase32)
        XCTAssertEqual(original.digits, 8)
        XCTAssertEqual(original.notes, "backup codes in the safe")
        XCTAssertTrue(original.favorite)
        XCTAssertTrue(original.usesAdvancedSettings)
        var edited = original
        XCTAssertFalse(edited.hasChanges(from: original))
        edited.notes += "!"
        XCTAssertTrue(edited.hasChanges(from: original))

        let blank = TotpForm(record: VaultRecord())
        XCTAssertEqual(blank.algorithm, "SHA1")
        XCTAssertFalse(blank.usesAdvancedSettings)
    }

    func testNewSeedPhraseCountsAsChangedOnlyOnceSomethingIsKept() {
        var record = VaultRecord(); record.type = "seed"; record.fields = []
        let original = SeedForm(record: record, isNew: true)
        XCTAssertEqual(original.mode, "generate")
        XCTAssertFalse(original.acknowledged)
        var form = original
        form.generated = Array(repeating: "abandon", count: 12)
        XCTAssertFalse(form.hasChanges(from: original), "a suggested phrase nobody confirmed is nothing to lose")
        form.acknowledged = true
        XCTAssertTrue(form.hasChanges(from: original), "confirmed words are")
        form = original
        form.mode = "enter"
        XCTAssertFalse(form.hasChanges(from: original), "switching mode with nothing typed")
        form.typed = "abandon ability"
        XCTAssertTrue(form.hasChanges(from: original))
        form = original
        form.name = "Cold wallet"
        XCTAssertTrue(form.hasChanges(from: original))
    }

    func testSavedSeedPhraseNoticesEditedWords() throws {
        let words = Array(repeating: "abandon", count: 11) + ["about"]
        var record = VaultRecord(); record.type = "seed"; record.fields = []
        record = try record.editingSeed(name: "Wallet", favorite: false, words: words, privateKey: nil, passphrase: "", notes: "")
        let original = SeedForm(record: record, isNew: false)
        XCTAssertEqual(original.mode, "enter")
        XCTAssertTrue(original.acknowledged)
        var form = original
        form.typed = words.joined(separator: "  ")
        XCTAssertFalse(form.hasChanges(from: original), "extra spaces store the same words")
        form.mode = "generate"; form.acknowledged = false
        XCTAssertFalse(form.hasChanges(from: original), "an unconfirmed suggestion keeps the saved words")
        form = original
        form.typed = words.dropLast().joined(separator: " ")
        XCTAssertTrue(form.hasChanges(from: original))
    }

    func testRecordFormChangesAreAnyDifference() {
        let original = VaultRecord()
        var edited = original
        XCTAssertFalse(edited.hasChanges(from: original))
        edited.name = "Bank"
        XCTAssertTrue(edited.hasChanges(from: original))
    }
}
