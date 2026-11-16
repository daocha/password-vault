import XCTest
import SwiftUI
import VaultCore
@testable import PassVault

/// Folding and unfolding moves the open entry between sheets and the side pane. These check that a width change never
/// closes the entry or drops an unsaved edit, while closing a sheet on a narrow screen still does.
@MainActor final class EntryPaneModelTests: XCTestCase {
    private func login(_ name: String) -> VaultRecord { var record = VaultRecord(); record.name = name; return record }

    private func recordDraft(_ pane: EntryPaneModel) -> EditorDraft<VaultRecord>? {
        if case .record(let draft) = pane.state.editor { return draft }
        return nil
    }

    func testUnfoldingWhileEditingKeepsTheDraftAndFoldingBringsItBack() throws {
        let pane = EntryPaneModel(), bank = login("Bank")
        pane.open(bank.id)
        pane.edit(bank)
        let draft = try XCTUnwrap(recordDraft(pane))
        draft.form.name = "Bank (joint)"
        let narrow = pane.hooks(inPane: false).editorItem
        XCTAssertEqual(narrow.wrappedValue?.id, draft.id, "a narrow screen shows the editor as a sheet over the details")

        // Unfold: the sheet goes away (SwiftUI may write nil back), the pane shows the same draft.
        pane.wide = true
        XCTAssertNil(pane.hooks(inPane: false).editorItem.wrappedValue)
        pane.hooks(inPane: false).editorItem.wrappedValue = nil
        XCTAssertTrue(recordDraft(pane) === draft)
        XCTAssertEqual(pane.state.viewing, bank.id)

        // Fold again: the same draft, with the typed name, returns as a sheet.
        pane.wide = false
        XCTAssertEqual(pane.hooks(inPane: false).editorItem.wrappedValue?.id, draft.id)
        XCTAssertEqual(recordDraft(pane)?.form.name, "Bank (joint)")
    }

    /// iPad or unfolded foldable held upright: an entry open beside the list must not pop up over Vault health's report.
    func testVaultHealthShowsOnlyTheEntriesItOpened() {
        let pane = EntryPaneModel(), bank = login("Bank"), mail = login("Mail")
        pane.wide = true
        pane.open(bank.id)
        pane.healthSheet = true
        XCTAssertNil(pane.entryOverReport, "the list's entry stays in its pane, behind the report")
        XCTAssertNil(pane.hooks(inPane: true).editorItem.wrappedValue)
        XCTAssertNil(pane.narrowNewEditor.wrappedValue, "nothing else pops up over the report")

        pane.openFromHealth(mail.id)
        XCTAssertEqual(pane.entryOverReport?.id, mail.id, "an entry opened from the report shows over it")
        pane.edit(mail)
        XCTAssertNotNil(pane.hooks(inPane: false).editorItem.wrappedValue, "its editor opens over its details")
        XCTAssertNil(pane.hooks(inPane: true).editorItem.wrappedValue, "never a second time from the pane behind")
    }

    func testAnEntryOpenedBesideTheReportFollowsItUpright() {
        let pane = EntryPaneModel(), bank = login("Bank")
        pane.wide = true
        pane.openFromHealth(bank.id) // In landscape, beside the report.
        XCTAssertNil(pane.entryOverReport)
        pane.healthSheet = true // Turned upright: the report pops up over the list.
        XCTAssertEqual(pane.entryOverReport?.id, bank.id)
    }

    func testSwipingTheSheetAwayOnANarrowScreenDiscardsTheEdit() {
        let pane = EntryPaneModel(), bank = login("Bank")
        pane.open(bank.id)
        pane.edit(bank)
        pane.hooks(inPane: false).editorItem.wrappedValue = nil
        XCTAssertNil(pane.state.editor)
        XCTAssertEqual(pane.state.presentation, .detail(bank.id), "the details stay open, as before")
    }

    func testNewEntryEditorSurvivesWidthChanges() throws {
        let pane = EntryPaneModel()
        pane.create(VaultRecord())
        let draft = try XCTUnwrap(recordDraft(pane))
        draft.form.name = "Shop"
        XCTAssertNotNil(pane.narrowNewEditor.wrappedValue)
        pane.wide = true
        XCTAssertNil(pane.narrowNewEditor.wrappedValue, "a wide screen shows it in the pane instead")
        pane.narrowNewEditor.wrappedValue = nil
        XCTAssertTrue(recordDraft(pane) === draft)
        pane.wide = false
        XCTAssertEqual(pane.narrowNewEditor.wrappedValue?.id, draft.id)
        pane.narrowNewEditor.wrappedValue = nil
        XCTAssertNil(pane.state.editor, "swiping a new entry away on a narrow screen discards it, as before")
    }

    func testTappingAnotherEntryWithUnsavedEditsAsksFirst() throws {
        let pane = EntryPaneModel(), bank = login("Bank"), mail = login("Mail")
        pane.wide = true
        pane.open(bank.id)
        pane.edit(bank)
        pane.open(mail.id)
        XCTAssertEqual(pane.state.viewing, mail.id, "an untouched editor gives way")

        pane.edit(mail)
        try XCTUnwrap(recordDraft(pane)).form.name = "Mail (work)"
        XCTAssertTrue(pane.hasUnsavedChanges)
        pane.open(bank.id)
        XCTAssertNotNil(pane.state.pending)
        XCTAssertEqual(pane.state.viewing, mail.id)
        pane.state.keepEditing()
        XCTAssertEqual(recordDraft(pane)?.form.name, "Mail (work)")
        pane.create(VaultRecord())
        XCTAssertNotNil(pane.state.pending, "New entry asks too")
        pane.state.discardChanges()
        XCTAssertEqual(pane.state.presentation, .newEditor)
    }

    func testSavingANewEntryOpensItBesideTheListOnlyWhenWide() {
        let pane = EntryPaneModel()
        pane.wide = true
        pane.create(VaultRecord())
        pane.editorDone("saved")
        XCTAssertEqual(pane.state.presentation, .detail("saved"))

        pane.wide = false
        pane.state.close()
        pane.create(VaultRecord())
        pane.editorDone("saved")
        XCTAssertEqual(pane.state.presentation, .none)
    }

    func testEditorsForEachKindKeepTheirOwnFields() throws {
        let pane = EntryPaneModel()
        var code = try TotpAccount(secret: Data([1, 2, 3, 4, 5]), issuer: "Example").record(); code.name = "Example"
        pane.open(code.id)
        pane.edit(code)
        guard case .totp(let totp, let original) = pane.state.editor else { return XCTFail("expected the 2FA editor") }
        XCTAssertEqual(original.id, code.id)
        totp.form.account = "me@example.com"
        XCTAssertTrue(pane.hasUnsavedChanges)

        var seed = VaultRecord(); seed.type = "seed"; seed.fields = []
        pane.state.close()
        pane.create(seed)
        guard case .seed(let draft, _, let isNew) = pane.state.editor else { return XCTFail("expected the seed editor") }
        XCTAssertTrue(isNew)
        XCTAssertEqual(draft.form.mode, "generate")
        XCTAssertFalse(pane.hasUnsavedChanges)
    }

    func testDetailHooksCloseAndEditThroughTheList() {
        let pane = EntryPaneModel(), bank = login("Bank")
        pane.open(bank.id)
        let hooks = pane.hooks(inPane: true)
        XCTAssertTrue(hooks.inPane)
        hooks.edit(bank)
        XCTAssertEqual(pane.state.presentation, .detailAndEditor(bank.id))
        hooks.editorDone(nil)
        XCTAssertEqual(pane.state.presentation, .detail(bank.id))
        hooks.close()
        XCTAssertEqual(pane.state.presentation, .none)
        XCTAssertNil(EntryPaneHooks.editorItem(nil, ready: true).wrappedValue, "detail views opened elsewhere present no list editor")
    }

    func testEveryEditorGetsItsOwnIdentity() {
        let pane = EntryPaneModel(), bank = login("Bank")
        pane.open(bank.id)
        var seen = Set<UUID>()
        for _ in 0..<50 {
            pane.edit(bank)
            guard let id = pane.state.editor?.id else { return XCTFail("no editor") }
            XCTAssertTrue(seen.insert(id).inserted, "a new editor must not reuse an earlier one's view state")
            pane.editorDone(nil)
        }
    }
}
