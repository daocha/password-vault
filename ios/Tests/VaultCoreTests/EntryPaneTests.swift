import XCTest
@testable import VaultCore

final class EntryPaneTests: XCTestCase {
    func testOnlyAPhoneInLandscapeMovesTheTabsAboveThePane() {
        XCTAssertTrue(EntryPaneLayout.tabsInSidePane(regularWidth: false, compactHeight: true), "any iPhone in landscape")
        XCTAssertTrue(EntryPaneLayout.tabsInSidePane(regularWidth: true, compactHeight: true), "a large iPhone in landscape")
        XCTAssertFalse(EntryPaneLayout.tabsInSidePane(regularWidth: true, compactHeight: false), "an iPad has the height to keep them above the list")
        XCTAssertFalse(EntryPaneLayout.tabsInSidePane(regularWidth: false, compactHeight: false), "an upright iPhone has no pane")
    }

    func testThePaneSitsBesideTheListOnWideWindowsAndPhonesTurnedSideways() {
        XCTAssertTrue(EntryPaneLayout.showsSidePane(regularWidth: true, compactHeight: false), "an iPad or an unfolded foldable iPhone")
        XCTAssertTrue(EntryPaneLayout.showsSidePane(regularWidth: true, compactHeight: true), "a large iPhone in landscape")
        XCTAssertTrue(EntryPaneLayout.showsSidePane(regularWidth: false, compactHeight: true), "any iPhone in landscape")
        XCTAssertFalse(EntryPaneLayout.showsSidePane(regularWidth: false, compactHeight: false), "an iPhone held upright keeps the full-screen details")
    }

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

    func testSavingAnEditorKeepsChangesMadeElsewhereMeanwhile() {
        var base = VaultRecord(); base.name = "Bank"; base.group = "Personal"; base.legacy["totpOrder"] = "3"
        // Meanwhile, from the list beside the editor: a new group and a 2FA reorder.
        var current = base; current.group = "Family"; current.legacy["totpOrder"] = "1"; current.updatedAt = "later"
        // The editor changed only the name and the password.
        var edited = base; edited.name = "Bank (joint)"; edited.fields[1].value = "new secret"; edited.updatedAt = "saved"
        let result = current.applyingEdits(edited, since: base)
        XCTAssertEqual(result.name, "Bank (joint)")
        XCTAssertEqual(result.fields[1].value, "new secret")
        XCTAssertEqual(result.group, "Family", "the group set from the list is kept")
        XCTAssertEqual(result.legacy["totpOrder"], "1", "the 2FA order is kept")
        XCTAssertEqual(result.updatedAt, "saved")
    }

    func testEditorsOwnChangesWinOverChangesElsewhere() {
        var base = VaultRecord(); base.group = "Personal"; base.favorite = false; base.legacy["note"] = "x"
        var current = base; current.group = "Family"; current.favorite = true
        var edited = base; edited.group = "Work"; edited.legacy["note"] = nil; edited.expires = "2030-01-01"
        let result = current.applyingEdits(edited, since: base)
        XCTAssertEqual(result.group, "Work", "what the person set in the editor is saved")
        XCTAssertTrue(result.favorite, "a favorite set elsewhere is kept when the editor left it alone")
        XCTAssertNil(result.legacy["note"], "a value the editor removed stays removed")
        XCTAssertEqual(result.expires, "2030-01-01")
    }

    func testUnchangedEditorLeavesTheCurrentEntryAsItIs() {
        var base = VaultRecord(); base.name = "Mail"
        var current = base; current.name = "Mail (work)"; current.fields.append(VaultField(kind: .note, label: "Extra", value: "kept"))
        let result = current.applyingEdits(base, since: base)
        XCTAssertEqual(result.name, "Mail (work)")
        XCTAssertEqual(result.fields, current.fields)
    }

    /// Codex review: editing only Notes while the password changed in Vault health must not bring the old password back.
    func testEditingOneFieldKeepsAnotherFieldChangedMeanwhile() {
        var base = VaultRecord(); base.fields[1].value = "old password"; base.fields[2].value = "notes"
        var current = base; current.fields[1].value = "new password"
        current.fields[1].history = [PasswordChange(value: "old password", changedAt: 1)]
        var edited = base; edited.fields[2].value = "notes, edited"
        let result = current.applyingEdits(edited, since: base)
        XCTAssertEqual(result.fields[1].value, "new password")
        XCTAssertEqual(result.fields[1].history?.count, 1)
        XCTAssertEqual(result.fields[2].value, "notes, edited")
        XCTAssertEqual(result.fields.map(\.id), base.fields.map(\.id))
    }

    func testFieldsAddedOrRemovedOnEitherSide() {
        let base = VaultRecord()
        let extra = VaultField(kind: .note, label: "Imported", value: "kept")
        var current = base; current.fields.append(extra); current.fields.remove(at: 0)
        var edited = base
        let question = VaultField(kind: .question, label: "Security question", value: "blue")
        edited.fields.append(question); edited.fields.remove(at: 2)
        let result = current.applyingEdits(edited, since: base)
        XCTAssertEqual(result.fields.map(\.id), [base.fields[1].id, question.id, extra.id],
                       "deleted elsewhere stays deleted, removed in the editor goes, both sides' new fields stay")
    }

    func testBothChangingOneFieldKeepsTheEditorsValueAndTheNewestHistory() {
        var base = VaultRecord(); base.fields[1].value = "one"
        var current = base; current.fields[1].value = "two"; current.fields[1].history = [PasswordChange(value: "one", changedAt: 1)]
        var edited = base; edited.fields[1].value = "three"
        let result = current.applyingEdits(edited, since: base).recordingPasswordChanges(previous: current, at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(result.fields[1].value, "three")
        XCTAssertEqual(result.fields[1].historyNewestFirst.map(\.value), ["two", "one"], "no password is lost")
    }

    func testSeedNameEditKeepsItsFieldsAndOnesAddedMeanwhile() throws {
        let words = Array(repeating: "abandon", count: 11) + ["about"]
        var seed = VaultRecord(); seed.type = "seed"; seed.fields = []
        let base = try seed.editingSeed(name: "Wallet", favorite: false, words: words, privateKey: nil, passphrase: "p", notes: "n")
        let edited = try base.editingSeed(name: "Cold wallet", favorite: false, words: words, privateKey: nil, passphrase: "p", notes: "n")
        XCTAssertEqual(edited.fields, base.fields, "an unchanged phrase, passphrase and note stay the same fields")
        var current = base; current.fields.append(VaultField(kind: .note, label: "Imported", value: "kept"))
        let result = current.applyingEdits(edited, since: base)
        XCTAssertEqual(result.name, "Cold wallet")
        XCTAssertEqual(result.fields, current.fields)
    }

    /// Codex review: a key typed into a new code and then hidden must stay hidden when a fold rebuilds the editor.
    func testSetupKeyStaysHiddenWhenTheEditorIsRebuilt() {
        var form = TotpForm(record: VaultRecord())
        XCTAssertTrue(form.keyStartsVisible(isNewCode: true), "an empty new key field is shown for typing")
        form.key = "JBSWY3DPEHPK3PXP"
        XCTAssertFalse(form.keyStartsVisible(isNewCode: true))
        XCTAssertFalse(form.keyStartsVisible(isNewCode: false))
    }
}
