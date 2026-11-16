import SwiftUI
import VaultCore

struct RecordList: View {
    @EnvironmentObject var model: VaultModel
    @State private var query = ""
    @State private var searchOpen = false
    @FocusState private var searchFocused: Bool
    @State private var favorites = false
    @State private var folder: String?
    @State private var kind: String?
    @State private var tab: VaultTab = .passwords
    /// The entry open beside the list (wide screens) or over it (narrow screens). It outlives width changes, so folding
    /// or unfolding the phone keeps the entry and any unsaved edits; it goes away with the list when the vault locks.
    @StateObject private var pane = EntryPaneModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var heightClass
    /// An iPad, an unfolded foldable iPhone, or an iPhone in landscape: details and editors open in a pane beside the list
    /// instead of over it. Turning the phone moves the open entry and any unsaved edits between the pane and full screen.
    private var wide: Bool { EntryPaneLayout.showsSidePane(regularWidth: sizeClass == .regular, compactHeight: heightClass == .compact) }
    /// A phone in landscape: the tabs sit above the side pane, leaving the short list column its rows.
    private var tabsBeside: Bool { EntryPaneLayout.tabsInSidePane(regularWidth: sizeClass == .regular, compactHeight: heightClass == .compact) }
    /// Vault health takes the list's place beside the pane: a wide screen in landscape (see EntryPaneLayout.healthBesidePane).
    private func healthBeside(landscape: Bool) -> Bool {
        EntryPaneLayout.healthBesidePane(regularWidth: sizeClass == .regular, compactHeight: heightClass == .compact, landscape: landscape)
    }
    @State private var pendingDeletion: Set<String>?
    @State private var reordering = false
    @State private var transfer = false
    /// What the Vault health sheet shows; the group to open travels with it so the sheet never reads stale state.
    @State private var healthTarget: HealthTarget?
    /// The window is wider than tall. Measured ignoring the keyboard, which would otherwise make an upright iPad typing
    /// in an editor look like one in landscape and move Vault health out of its sheet.
    @State private var windowLandscape = false
    /// Groups the person opened or closed in Vault health's report, kept here so turning the device (which moves the
    /// report between its sheet and the list's place) keeps them.
    @State private var healthFlipped: Set<String> = []
    /// Ids picked by tapping an entry's icon; any selection turns the header into the selection bar.
    @State private var selected = Set<String>()
    init(initialSelection: Set<String> = []) { _selected = State(initialValue: initialSelection) }
    @State private var confirmDelete = false
    @State private var grouping = false
    private var showTotp: Bool { tab == .totp }
    private var filter: VaultListFilter { VaultListFilter(tab: tab, query: query, favorites: favorites, folder: folder, kind: kind) }
    var body: some View {
        content(landscape: windowLandscape)
            .background(GeometryReader { window in
                Color.clear
                    .onAppear { windowLandscape = window.size.width > window.size.height }
                    .onChange(of: window.size) { _, size in windowLandscape = size.width > size.height }
            }.ignoresSafeArea(.keyboard))
    }
    private func content(landscape: Bool) -> some View {
        let snapshot = VaultListSnapshot(records: model.records, filter: filter)
        let healthInline = healthTarget != nil && healthBeside(landscape: landscape)
        let visibleSelected = snapshot.selection(from: selected)
        let selecting = !visibleSelected.isEmpty
        // Before any sheet reacts to a new width or orientation (see EntryPaneModel.wide).
        pane.wide = wide
        pane.healthSheet = healthTarget != nil && !healthInline
        return HStack(spacing: 0) {
            Group {
                if healthInline, let target = healthTarget {
                    HealthView(focus: target.focus, pane: pane, beside: true, close: closeHealth, flipped: $healthFlipped)
                } else {
                    listColumn(snapshot, visibleSelected: visibleSelected, selecting: selecting)
                }
            }
            .frame(minWidth: wide ? 320 : nil, maxWidth: wide ? 420 : .infinity)
            if wide {
                Divider().ignoresSafeArea()
                VStack(spacing: 0) {
                    if tabsBeside && !healthInline { tabBar.padding(.horizontal, 16).padding(.vertical, 8) }
                    if healthInline { EntryPaneView(pane: pane, hint: "Choose an entry from the report to see it here.") }
                    else { EntryPaneView(pane: pane) }
                }
            }
        }
        .background(Color.aBackground)
        .onChange(of: model.records.map(\.id)) { _, ids in pane.state.keepOnly(Set(ids)) }
        // The buttons decide; the binding's setter does nothing, so Discard works whichever order SwiftUI runs the button and the dismissal in.
        // Over Vault health's sheet the report asks instead (an alert here would be hidden behind it).
        .alert("Discard unsaved changes?", isPresented: Binding(get: { pane.state.pending != nil && !pane.healthSheet }, set: { _ in })) {
            Button("Discard", role: .destructive) { pane.state.discardChanges() }
            Button("Keep editing", role: .cancel) { pane.state.keepEditing() }
        } message: { Text("The entry you are editing has changes that are not saved.") }
    }
    private func listColumn(_ snapshot: VaultListSnapshot, visibleSelected: Set<String>, selecting: Bool) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selecting { selectionBar(snapshot, selected: visibleSelected) } else { vaultToolbar }
                listControls(snapshot)
                VStack(alignment: .leading, spacing: 8) {
                    if !selecting { notices }
                    recordSummary(snapshot, selecting: selecting)
                }.padding(.horizontal, 16).padding(.bottom, 8)
                List {
                    if snapshot.total == 0 { emptyState.listRowBackground(Color.clear) }
                    ForEach(snapshot.visible) { record in
                        let isSelected = visibleSelected.contains(record.id)
                        let isOpen = wide && !selecting && pane.state.viewing == record.id
                        let selection = RowSelection(selecting: selecting, isSelected: isSelected) { toggle(record) }
                        Group {
                            if record.isTotp { TotpRow(record: record, selection: selection) }
                            else { VaultEntryRow(record: record, selection: selection) }
                        }
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, record.showsExpiryBadge ? 32 : 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.aCard, in: RoundedRectangle(cornerRadius: 16))
                        // The entry shown in the side pane.
                        .overlay { if isOpen { RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: 2) } }
                        .accessibilityAddTraits(isOpen ? .isSelected : [])
                        .overlay(alignment: .bottomTrailing) { ExpiryBadge(record: record).padding(.trailing, 12).padding(.bottom, 8) }
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture {
                            if selecting { toggle(record) } else { pane.open(record.id) }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isButton)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }.onDelete { offsets in pendingDeletion = Set(offsets.map { snapshot.visible[$0].id }) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 88, for: .scrollContent)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
                    if searchOpen { searchFocused = false; searchOpen = false }
                })
            }
            .background(Color.aBackground)
            .overlay(alignment: .bottomTrailing) {
                if !selecting {
                    addEntryButton.buttonStyle(.borderedProminent).foregroundStyle(Color.aOnPrimary)
                        .buttonBorderShape(.roundedRectangle(radius: 16)).controlSize(.large).padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: searchOpen) { _, open in if open { searchFocused = true } }
            .onChange(of: tab) { _, _ in query = ""; folder = nil; kind = nil; selected = [] }
            .onChange(of: snapshot.ids) { _, _ in selected = snapshot.selection(from: selected) }
            .sensoryFeedback(.selection, trigger: selected)
            .onChange(of: snapshot.folders) { _, names in if let folder, !names.contains(folder) { self.folder = nil } }
            .onChange(of: snapshot.kinds) { _, names in if let kind, !names.contains(kind) { self.kind = nil } }
            // Narrow screens: the open entry full screen, a new entry's editor as a sheet, as before the side pane existed.
            .fullScreenCover(item: narrowDetail) { item in
                if let record = model.records.first(where: { $0.id == item.id }) { OpenEntryDetail(pane: pane, record: record, inPane: false) }
            }
            .sheet(item: pane.narrowNewEditor) { item in item.view(done: { pane.editorDone($0) }) }
            .sheet(isPresented: $grouping) { GroupAssignSheet(records: model.records, ids: visibleSelected) { selected = [] } }
            .confirmationDialog(deleteTitle(visibleSelected), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let ids = VaultListSnapshot(records: model.records, filter: filter).selection(from: selected)
                    selected = []; saveDeletion(ids)
                }
            } message: { Text(deletionMessage(visibleSelected)) }
            .sheet(isPresented: $reordering) { TotpReorderView(codes: model.records.filter(\.isTotp).sorted(by: TotpOrder.less)) }
            .confirmationDialog("Delete this entry?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { let ids = pendingDeletion ?? []; pendingDeletion = nil; saveDeletion(ids) }
            } message: { Text(deletionMessage(pendingDeletion ?? [])) }
            .sheet(isPresented: $transfer) { TransferView() }
            .sheet(item: healthSheet) { HealthView(focus: $0.focus, pane: pane, close: closeHealth, flipped: $healthFlipped) }
            .fullScreenCover(item: $model.sending) { TransferSendView(payload: $0) }
        }
    }
    /// The open entry's details, presented over the list on a narrow screen. Closing them closes the entry; a change to a
    /// wide screen also takes them away, but keeps the entry open for the side pane.
    private var narrowDetail: Binding<OpenEntryItem?> {
        Binding(get: {
            // Over Vault health's sheet the report shows the entry instead.
            guard !wide, !pane.healthSheet else { return nil }
            switch pane.state.presentation {
            case .detail(let id), .detailAndEditor(let id): return OpenEntryItem(id: id)
            case .none, .newEditor: return nil
            }
        }, set: { item in if item == nil && !pane.wide && !pane.healthSheet { pane.state.close() } })
    }
    /// Vault health over the list, upright. In landscape on a wide screen it sits in the list's place instead; turning the
    /// device takes the sheet away without closing the report.
    private var healthSheet: Binding<HealthTarget?> {
        Binding(get: { pane.healthSheet ? healthTarget : nil }, set: { item in if item == nil && pane.healthSheet { closeHealth() } })
    }
    /// Closes Vault health. Which entry it opened is forgotten, so a later report never shows an entry the list opened.
    private func closeHealth() { healthTarget = nil; pane.fromHealth = nil; healthFlipped = [] }
    private func listControls(_ snapshot: VaultListSnapshot) -> some View {
        return VStack(spacing: 8) {
            if !tabsBeside { tabBar }
            if searchOpen {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.aOnSurfaceVariant)
                    TextField("Search names, usernames, notes", text: $query).font(.system(size: 15)).focused($searchFocused).submitLabel(.search)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    VaultFilterChip(title: localized("Favorites"), icon: favorites ? "star.fill" : "star", selected: favorites) { favorites.toggle() }
                    if tab == .passwords {
                        if snapshot.kinds.contains("card") { VaultFilterChip(title: localized("Cards"), icon: "creditcard", selected: kind == "card") { kind = kind == "card" ? nil : "card" } }
                        if snapshot.kinds.contains("note") { VaultFilterChip(title: localized("Notes"), icon: "note.text", selected: kind == "note") { kind = kind == "note" ? nil : "note" } }
                        ForEach(snapshot.folders, id: \.self) { name in
                            VaultFilterChip(title: name, icon: "folder", selected: folder == name, tint: groupColor(name), alwaysOutlined: true) { folder = folder == name ? nil : name }
                                .accessibilityIdentifier("folder.\(name)")
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 16).padding(.bottom, 4)
    }
    private func tabIcon(_ tab: VaultTab) -> String {
        switch tab { case .passwords: "key"; case .seed: "wallet.bifold"; case .totp: "number" }
    }
    /// Three joined buttons, each with its icon before the label, like Android's segmented row.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(VaultTab.allCases.enumerated()), id: \.element) { index, item in
                if index > 0 { Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 1) }
                Button { if tab != item { tab = item } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tabIcon(item)).font(.system(size: 13))
                        Text(LocalizedStringKey(item.label)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.aOnSurface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tab == item ? Color.accentColor.opacity(0.2) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab.\(item.rawValue)")
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .frame(height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.5), lineWidth: 1))
    }
    private func toggle(_ record: VaultRecord) {
        if !selected.insert(record.id).inserted { selected.remove(record.id) }
    }
    private func deleteTitle(_ ids: Set<String>) -> String {
        localizedFormat(ids.count == 1 ? "Delete %lld entry?" : "Delete %lld entries?", ids.count)
    }
    private func deletionMessage(_ ids: Set<String>) -> String {
        let doomed = model.records.filter { ids.contains($0.id) }
        if doomed.contains(where: \.isFileKey) { return localized(fileKeyDeletionMessage) }
        let codes = doomed.filter(\.isTotp).count
        if codes > 0 { return localizedFormat("This includes %lld 2FA codes. Without another copy of their setup keys or the sites' recovery codes, you may lose access to those accounts.", codes) }
        let seeds = doomed.filter(\.isSeed).count
        if seeds == 0 { return localized("They will be permanently removed from this vault.") }
        return localizedFormat(seeds == 1 ? "They will be permanently removed from this vault. This includes %lld seed phrase: without another backup, those wallets cannot be recovered." : "They will be permanently removed from this vault. This includes %lld seed phrases: without another backup, those wallets cannot be recovered.", seeds)
    }
    /// Replaces the header while entries are selected: cancel, count, select all, group (passwords only) and delete.
    private func selectionBar(_ snapshot: VaultListSnapshot, selected visibleSelected: Set<String>) -> some View {
        return HStack(spacing: 0) {
            Button { selected = [] } label: { Label("Cancel selection", systemImage: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
            Text(localizedFormat("%lld selected", visibleSelected.count)).font(.title3).lineLimit(1).padding(.leading, 4)
            Spacer(minLength: 0)
            Button {
                selected = snapshot.togglingAll(selected)
            } label: { Label("Select all", systemImage: "checklist").frame(width: 44, height: 44).contentShape(Rectangle()) }
            if tab == .passwords {
                Button { grouping = true } label: { Label("Change group of selected", systemImage: "folder").frame(width: 44, height: 44).contentShape(Rectangle()) }
            }
            Button { confirmDelete = true } label: { Label("Delete selected", systemImage: "trash").frame(width: 44, height: 44).contentShape(Rectangle()) }
        }
        .labelStyle(.iconOnly).font(.title3).buttonStyle(.plain).foregroundStyle(Color.aOnSurface)
        .padding(.horizontal, 16).frame(minHeight: 56)
        .background(Color.accentColor.opacity(0.18))
    }
    @ViewBuilder private func recordSummary(_ snapshot: VaultListSnapshot, selecting: Bool) -> some View {
        if snapshot.total > 0 {
            HStack {
                Text(localizedFormat(showTotp ? "%lld of %lld codes" : tab == .seed ? "%lld of %lld seed phrases" : "%lld of %lld entries", snapshot.visible.count, snapshot.total))
                    .font(.caption).foregroundStyle(Color.aOnSurfaceVariant)
                Spacer()
                if showTotp && snapshot.total > 1 && !selecting {
                    Button {
                        searchOpen = false; searchFocused = false; reordering = true
                    } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                    .font(.callout.weight(.medium)).accessibilityIdentifier("totp-reorder-button")
                }
            }.frame(minHeight: 24)
        }
    }
    /// Backup and expiry notices on a tinted background, like Android's AttentionBanner and SlimNotice.
    @ViewBuilder private var notices: some View {
        if model.backupDue {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.lastBackup.map { localizedFormat("Last backup %@ · %lld entries changed since", $0.formatted(.relative(presentation: .named)), BackupReminder.changedSince(model.records, lastBackup: model.backupSnapshotAt)) }
                      ?? localized("No backup yet. If this phone is lost or reset, these entries are gone."), systemImage: "externaldrive.badge.exclamationmark").font(.footnote)
                HStack { Button("Back up") { transfer = true }; Spacer(); Button("Later") { model.snoozeBackup() }.foregroundStyle(Color.aOnSurfaceVariant) }.buttonStyle(.borderless).font(.footnote)
            }
            .foregroundStyle(Color.noticeText)
            .padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.noticeBackground, in: RoundedRectangle(cornerRadius: 16))
        }
        let expiring = model.records.filter { $0.needsNotice() }.count
        if expiring > 0 {
            Button { healthTarget = HealthTarget(focus: "expiring") } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 15))
                    Text("Expired or due within 14 days: \(expiring)").font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Review").font(.footnote.weight(.medium)).foregroundStyle(Color.accentColor)
                }
                .foregroundStyle(Color.aOnSurface).padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.noticeBackground, in: RoundedRectangle(cornerRadius: 12)).contentShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
        }
    }
    @ViewBuilder private var emptyState: some View {
        if tab == .seed {
            ContentUnavailableView("No seed phrases", systemImage: "wallet.bifold", description: Text("Generate or enter a 12- or 24-word BIP-39 seed phrase, or store a wallet private key. Keep phrases for wallets with significant funds offline."))
        } else if showTotp {
            ContentUnavailableView("No 2FA codes", systemImage: "number", description: Text("Tap Add 2FA code to scan a QR code or enter its setup key."))
        } else {
            ContentUnavailableView("A little peace of mind", systemImage: "key", description: Text("Add your first password or import your Password Keeper CSV."))
        }
    }
    private func saveDeletion(_ ids: Set<String>) {
        let updated = model.records.filter { !ids.contains($0.id) }
        model.run { try $0.save(updated); return updated }
    }
    /// A plain header keeps the wordmark out of iOS's automatic toolbar button backgrounds.
    private var vaultToolbar: some View {
        HStack(spacing: 8) {
            WordMark().font(.title2.bold()).lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityLabel("PassVault")
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { searchOpen.toggle() } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .foregroundStyle(query.isEmpty ? Color.primary : Color.accentColor)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                Button { healthTarget = HealthTarget(focus: nil) } label: {
                    Label("Vault health", systemImage: "checkmark.shield").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                Button { model.lock() } label: {
                    Label("Lock vault", systemImage: "lock").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                Button { transfer = true } label: {
                    Label("Settings", systemImage: "gearshape").frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityIdentifier("vault.settings")
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .foregroundStyle(Color.aOnSurface)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(.background)
    }

    private var addEntryButton: some View {
        Group {
            if tab == .seed {
                Button {
                    var record = VaultRecord(); record.type = "seed"; record.fields = []; pane.create(record)
                } label: { Label("New seed phrase", systemImage: "plus") }
            } else if showTotp {
                Button {
                    var record = VaultRecord(); record.type = "totp"; record.fields = []; pane.create(record)
                } label: {
                    Label("Add 2FA code", systemImage: "qrcode.viewfinder")
                }
            } else {
                // Login, Payment card, Secure note from top to bottom; fixed order keeps iOS from flipping it when the menu opens upward.
                Menu {
                    Button("Login", systemImage: "key") { pane.create(VaultRecord()) }
                    Button("Payment card", systemImage: "creditcard") { pane.create(VaultRecord.new(type: "card")) }
                    Button("Secure note", systemImage: "note.text") { pane.create(VaultRecord.new(type: "note")) }
                } label: {
                    Label("New entry", systemImage: "plus")
                }.menuOrder(.fixed)
            }
        }
    }
}

private struct VaultFilterChip: View {
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = 13.0
    let title: String
    let icon: String
    let selected: Bool
    var tint: Color = .accentColor
    /// Folder chips keep their group color on the border even when not selected, as on Android and in each entry's tag.
    var alwaysOutlined = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(Color.aOnSurface).padding(.horizontal, 10).frame(minHeight: 32)
                .background(selected ? tint.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected || alwaysOutlined ? tint : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1))
                .padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityValue(selected ? localized("On") : localized("Off"))
    }
}

extension VaultRecord {
    /// Expired or due soon: the list shows a badge at the row's bottom right.
    var showsExpiryBadge: Bool { [.expired, .soon].contains(expiryState()) }
}

/// What a list row needs to take part in multi-select: tapping its icon toggles it, and while anything is selected the icon is a check circle.
struct RowSelection {
    let selecting: Bool
    let isSelected: Bool
    let toggle: () -> Void
}

/// The row's leading 44pt control: the entry's icon (tap to select), or the selection circle while selecting.
struct RowLeading: View {
    let record: VaultRecord
    var selection: RowSelection?
    @ViewBuilder private var listAvatar: some View {
        if record.isSeed { IconBadge(symbol: "wallet.bifold", size: 44, tint: .noticeText, container: .noticeBackground) }
        else { RecordAvatar(record: record, size: 44) }
    }
    var body: some View {
        if let selection {
            Button(action: selection.toggle) {
                Group {
                    if selection.selecting {
                        Image(systemName: selection.isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: 28))
                            .foregroundStyle(selection.isSelected ? Color.accentColor : Color.secondary)
                    } else { listAvatar }
                }.frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(selection.selecting ? (selection.isSelected ? localized("Selected") : localized("Not selected")) : localized("Select"))
        } else {
            listAvatar.frame(width: 44, height: 44)
        }
    }
}

/// Material's titleMedium/bodyMedium sizes, weights and line heights, scaled for Accessibility.
struct VaultEntryRow: View {
    let record: VaultRecord
    var selection: RowSelection?
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var titleSize = 15.0
    @ScaledMetric(relativeTo: .subheadline) private var subtitleSize = 13.0
    @ScaledMetric(relativeTo: .body) private var titleHeight = 22.0
    @ScaledMetric(relativeTo: .subheadline) private var subtitleHeight = 18.0
    private var subtitle: String {
        if record.isTotp { return record.totp?.account ?? "" }
        if record.isSeed { return record.privateKey == nil ? localizedFormat("%lld words", record.seedWords.count) : localized("Private key") }
        if record.isCard { return record.cardSummary }
        if record.isNote { return record.fields.first { $0.kind == .note && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.value.components(separatedBy: .newlines).first ?? "" }
        return record.fields.first { $0.kind == .username && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.value ?? record.website
    }
    var body: some View {
        HStack(spacing: 16) {
            RowLeading(record: record, selection: selection)
            VStack(alignment: .leading, spacing: 0) {
                Text(record.name.isEmpty ? localized("Untitled record") : record.name)
                    .font(.system(size: titleSize, weight: .medium)).foregroundStyle(Color.aOnSurface)
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1).frame(minHeight: titleHeight, alignment: .leading)
                if !subtitle.isEmpty { Text(verbatim: subtitle).font(.system(size: subtitleSize)).foregroundStyle(Color.aOnSurfaceVariant).lineLimit(textSize.isAccessibilitySize ? 2 : 1).frame(minHeight: subtitleHeight, alignment: .leading) }
                if VaultTab.passwords.contains(record) && !VaultListFilter.folderName(record).isEmpty {
                    GroupTag(name: VaultListFilter.folderName(record)).padding(.top, 4)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if record.favorite { Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(Color.favoriteStar).accessibilityLabel("Favorites") }
            if let selection, !selection.selecting, !record.isTotp {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Stages a single group assignment for the visible selection; Cancel discards it and Apply commits it.
struct GroupAssignSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    let done: () -> Void
    @State private var newGroup = ""
    @State private var assignment: VaultGroupAssignment
    init(records: [VaultRecord], ids: Set<String>, done: @escaping () -> Void) {
        self.done = done
        _assignment = State(initialValue: VaultGroupAssignment(records: records, ids: ids))
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New group", text: $newGroup).font(.system(size: 15)).submitLabel(.done).onSubmit(addNew)
                        Button("Add", action: addNew).disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    ForEach(assignment.names, id: \.self) { name in
                        let membership = assignment.membership(name)
                        Button { assignment.assign(membership == true ? "" : name) } label: {
                            HStack {
                                GroupTag(name: name)
                                Spacer()
                                Image(systemName: membership == true ? "checkmark.square.fill" : membership == nil ? "minus.square.fill" : "square")
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(localizedFormat(assignment.count == 1 ? "Group %lld entry" : "Group %lld entries", assignment.count)).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply", action: apply).disabled(model.busy || (!assignment.hasChanges && newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .disabled(model.busy)
        }.interactiveDismissDisabled(model.busy)
    }
    private func addNew() { assignment.add(newGroup); newGroup = "" }
    private func apply() {
        if !newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addNew() }
        guard assignment.hasChanges else { dismiss(); return }
        let updated = assignment.applying(to: model.records, now: VaultTimestamp.format())
        model.run({ try $0.save(updated); return updated }, done: { done(); dismiss() })
    }
}

struct HealthTarget: Identifiable {
    let id = UUID()
    let focus: String?
}

extension Color {
    /// Android's tertiaryContainer / onTertiaryContainer (see Theme.kt), light and dark, so the list notices match the Android app.
    static let noticeBackground = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x24 / 255, green: 0x50 / 255, blue: 0x24 / 255, alpha: 1) : UIColor(red: 0xBC / 255, green: 0xF0 / 255, blue: 0xB4 / 255, alpha: 1) })
    static let noticeText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0xBC / 255, green: 0xF0 / 255, blue: 0xB4 / 255, alpha: 1) : UIColor(red: 0x00, green: 0x22 / 255, blue: 0x04 / 255, alpha: 1) })
}

extension Color {
    /// The favourite star on every screen (same amber as Android), in light and dark.
    static let favoriteStar = Color(red: 1.0, green: 0.757, blue: 0.027)
}

