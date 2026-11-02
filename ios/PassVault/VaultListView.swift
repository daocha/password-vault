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
    @State private var editing: VaultRecord?
    @State private var viewing: VaultRecord?
    @State private var viewingTotp: VaultRecord?
    @State private var editingTotp: VaultRecord?
    @State private var viewingSeed: VaultRecord?
    @State private var editingSeed: VaultRecord?
    @State private var seedDeletion: Set<String>?
    @State private var reordering = false
    @State private var transfer = false
    @State private var health = false
    @State private var healthFocus: String?
    /// Ids picked by tapping an entry's icon; any selection turns the header into the selection bar.
    @State private var selected = Set<String>()
    @State private var confirmDelete = false
    @State private var grouping = false
    private var selecting: Bool { !selected.isEmpty }
    private var showTotp: Bool { tab == .totp }
    private var folders: [String] { VaultListFilter.folders(in: model.records) }
    private var tabRecords: [VaultRecord] { model.records.filter { tab.contains($0) } }
    private var filtered: [VaultRecord] {
        VaultListFilter(tab: tab, query: query, favorites: favorites, folder: folder, kind: kind).apply(to: model.records)
    }
    private var kinds: [String] { ["card", "note"].filter { kind in tabRecords.contains { $0.type == kind } } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if selecting { selectionBar } else { vaultToolbar }
                listControls
                VStack(alignment: .leading, spacing: 8) {
                    if !selecting { notices }
                    recordSummary
                }.padding(.horizontal, 16).padding(.bottom, 8)
                List {
                    if tabRecords.isEmpty { emptyState.listRowBackground(Color.clear) }
                    ForEach(filtered) { record in
                        let isSelected = selected.contains(record.id)
                        let selection = RowSelection(selecting: selecting, isSelected: isSelected) { toggle(record) }
                        Group {
                            if record.isTotp { TotpRow(record: record, selection: selection) }
                            else { VaultEntryRow(record: record, selection: selection) }
                        }
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, record.showsExpiryBadge ? 32 : 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(alignment: .bottomTrailing) { ExpiryBadge(record: record).padding(.trailing, 12).padding(.bottom, 8) }
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                        .onTapGesture {
                            if selecting { toggle(record) }
                            else if record.isTotp { viewingTotp = record }
                            else if record.isSeed { viewingSeed = record }
                            else { viewing = record }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isButton)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }.onDelete(perform: delete)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 88, for: .scrollContent)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
                    if searchOpen { searchFocused = false; searchOpen = false }
                })
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay(alignment: .bottomTrailing) {
                if !selecting {
                    addEntryButton.buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 16)).controlSize(.large).padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: searchOpen) { _, open in if open { searchFocused = true } }
            .onChange(of: tab) { _, _ in query = ""; folder = nil; kind = nil; selected = [] }
            .sensoryFeedback(.selection, trigger: selected)
            .onChange(of: folders) { _, names in if let folder, !names.contains(folder) { self.folder = nil } }
            .onChange(of: kinds) { _, names in if let kind, !names.contains(kind) { self.kind = nil } }
            .sheet(item: $editing) { RecordEditor(record: $0) }
            .fullScreenCover(item: $viewing) { RecordDetail(recordID: $0.id) }
            .fullScreenCover(item: $viewingTotp) { TotpDetail(recordID: $0.id) }
            .sheet(isPresented: $grouping) { GroupAssignSheet(ids: selected) { selected = [] } }
            .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { let ids = selected; selected = []; saveDeletion(ids) }
            } message: { Text(deleteMessage) }
            .sheet(item: $editingTotp) { TotpEditor(record: $0) }
            .sheet(item: $viewingSeed) { SeedDetail(recordID: $0.id) }
            .sheet(item: $editingSeed) { SeedEditor(initial: $0, isNew: true) }
            .sheet(isPresented: $reordering) { TotpReorderView(codes: model.records.filter(\.isTotp).sorted(by: TotpOrder.less)) }
            .confirmationDialog("Delete this seed phrase?", isPresented: Binding(get: { seedDeletion != nil }, set: { if !$0 { seedDeletion = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { let ids = seedDeletion ?? []; seedDeletion = nil; saveDeletion(ids) }
            } message: { Text("Without another backup, this wallet cannot be recovered.") }
            .sheet(isPresented: $transfer) { TransferView() }
            .sheet(isPresented: $health) { HealthView(focus: healthFocus) }
            .fullScreenCover(item: $model.sending) { TransferSendView(payload: $0) }
        }
    }
    private var listControls: some View {
        VStack(spacing: 8) {
            tabBar
            if searchOpen {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search names, usernames, notes", text: $query).focused($searchFocused).submitLabel(.search)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear search") }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    VaultFilterChip(title: localized("Favorites"), icon: favorites ? "star.fill" : "star", selected: favorites) { favorites.toggle() }
                    if tab == .passwords {
                        if kinds.contains("card") { VaultFilterChip(title: localized("Cards"), icon: "creditcard", selected: kind == "card") { kind = kind == "card" ? nil : "card" } }
                        if kinds.contains("note") { VaultFilterChip(title: localized("Notes"), icon: "note.text", selected: kind == "note") { kind = kind == "note" ? nil : "note" } }
                        ForEach(folders, id: \.self) { name in
                            VaultFilterChip(title: name, icon: "folder", selected: folder == name, tint: groupColor(name)) { folder = folder == name ? nil : name }
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
                        Image(systemName: tabIcon(item)).font(.system(size: 14))
                        Text(LocalizedStringKey(item.label)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
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
    private var deleteTitle: String {
        localizedFormat(selected.count == 1 ? "Delete %lld entry?" : "Delete %lld entries?", selected.count)
    }
    private var deleteMessage: String {
        let doomed = model.records.filter { selected.contains($0.id) }
        let seeds = doomed.filter(\.isSeed).count
        if seeds == 0 { return localized("They will be permanently removed from this vault.") }
        return localizedFormat(seeds == 1 ? "They will be permanently removed from this vault. This includes %lld seed phrase: without another backup, those wallets cannot be recovered." : "They will be permanently removed from this vault. This includes %lld seed phrases: without another backup, those wallets cannot be recovered.", seeds)
    }
    /// Replaces the header while entries are selected: cancel, count, select all, group (passwords only) and delete.
    private var selectionBar: some View {
        HStack(spacing: 0) {
            Button { selected = [] } label: { Label("Cancel selection", systemImage: "xmark").frame(width: 44, height: 44).contentShape(Rectangle()) }
            Text(localizedFormat("%lld selected", selected.count)).font(.title3).lineLimit(1).padding(.leading, 4)
            Spacer(minLength: 0)
            Button {
                let ids = Set(filtered.map(\.id)); selected = selected.isSuperset(of: ids) ? [] : ids
            } label: { Label("Select all", systemImage: "checklist").frame(width: 44, height: 44).contentShape(Rectangle()) }
            if tab == .passwords {
                Button { grouping = true } label: { Label("Change group of selected", systemImage: "folder").frame(width: 44, height: 44).contentShape(Rectangle()) }
            }
            Button { confirmDelete = true } label: { Label("Delete selected", systemImage: "trash").frame(width: 44, height: 44).contentShape(Rectangle()) }
        }
        .labelStyle(.iconOnly).font(.title3).buttonStyle(.plain).foregroundStyle(.primary)
        .padding(.horizontal, 16).frame(minHeight: 56)
        .background(Color.accentColor.opacity(0.18))
    }
    @ViewBuilder private var recordSummary: some View {
        if !tabRecords.isEmpty {
            HStack {
                Text(localizedFormat(showTotp ? "%lld of %lld codes" : tab == .seed ? "%lld of %lld seed phrases" : "%lld of %lld entries", filtered.count, tabRecords.count))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if showTotp && tabRecords.count > 1 && !selecting {
                    Button {
                        searchOpen = false; searchFocused = false; reordering = true
                    } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                    .font(.callout.weight(.medium)).accessibilityIdentifier("totp-reorder-button")
                }
            }.frame(minHeight: 24)
        }
    }
    @ViewBuilder private var notices: some View {
        if model.backupDue {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.lastBackup.map { localizedFormat("Last backup %@ · %lld entries changed since", $0.formatted(.relative(presentation: .named)), BackupReminder.changedSince(model.records, lastBackup: $0)) }
                      ?? localized("No backup yet. If this phone is lost or reset, these entries are gone."), systemImage: "externaldrive.badge.exclamationmark").font(.caption)
                HStack { Button("Back up") { transfer = true }; Spacer(); Button("Later") { model.snoozeBackup() }.foregroundStyle(.secondary) }.buttonStyle(.borderless)
            }.padding(.vertical, 4)
        }
        let expiring = model.records.filter { $0.needsNotice() }.count
        if expiring > 0 {
            Button { healthFocus = "expiring"; health = true } label: {
                HStack { Label("Expired or due within 14 days: \(expiring)", systemImage: "calendar.badge.exclamationmark").lineLimit(1); Spacer(); Text("Review") }.font(.footnote)
            }.padding(.vertical, 6)
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
    private func delete(_ offsets: IndexSet) {
        let ids = Set(offsets.map { filtered[$0].id })
        if model.records.contains(where: { ids.contains($0.id) && $0.isSeed }) { seedDeletion = ids }
        else { saveDeletion(ids) }
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
                Button { healthFocus = nil; health = true } label: {
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
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(.background)
    }

    private var addEntryButton: some View {
        Group {
            if tab == .seed {
                Button {
                    var record = VaultRecord(); record.type = "seed"; record.fields = []; editingSeed = record
                } label: { Label("New seed phrase", systemImage: "plus") }
            } else if showTotp {
                Button {
                    var record = VaultRecord(); record.type = "totp"; record.fields = []; editingTotp = record
                } label: {
                    Label("Add 2FA code", systemImage: "qrcode.viewfinder")
                }
            } else {
                Menu {
                    Button("Login", systemImage: "key") { editing = VaultRecord() }
                    Button("Payment card", systemImage: "creditcard") { editing = VaultRecord.new(type: "card") }
                    Button("Secure note", systemImage: "note.text") { editing = VaultRecord.new(type: "note") }
                } label: {
                    Label("New entry", systemImage: "plus")
                }
            }
        }
    }
}

private struct VaultFilterChip: View {
    @ScaledMetric(relativeTo: .subheadline) private var fontSize = 14.0
    let title: String
    let icon: String
    let selected: Bool
    var tint: Color = .accentColor
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.primary).padding(.horizontal, 10).frame(minHeight: 32)
                .background(selected ? tint.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? tint : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1))
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
    var body: some View {
        if let selection {
            Button(action: selection.toggle) {
                Group {
                    if selection.selecting {
                        Image(systemName: selection.isSelected ? "checkmark.circle.fill" : "circle").font(.system(size: 28))
                            .foregroundStyle(selection.isSelected ? Color.accentColor : Color.secondary)
                    } else { RecordIcon(record: record) }
                }.frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(selection.selecting ? (selection.isSelected ? localized("Selected") : localized("Not selected")) : localized("Select"))
        } else {
            RecordIcon(record: record).frame(width: 44, height: 44)
        }
    }
}

/// Material's titleMedium/bodyMedium sizes, weights and line heights, scaled for Accessibility.
struct VaultEntryRow: View {
    let record: VaultRecord
    var selection: RowSelection?
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var titleSize = 16.0
    @ScaledMetric(relativeTo: .subheadline) private var subtitleSize = 14.0
    @ScaledMetric(relativeTo: .body) private var titleHeight = 24.0
    @ScaledMetric(relativeTo: .subheadline) private var subtitleHeight = 20.0
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
                    .font(.system(size: titleSize, weight: .medium)).foregroundStyle(.primary)
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1).frame(minHeight: titleHeight, alignment: .leading)
                if !subtitle.isEmpty { Text(verbatim: subtitle).font(.system(size: subtitleSize)).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? 2 : 1).frame(minHeight: subtitleHeight, alignment: .leading) }
                if VaultTab.passwords.contains(record) && !VaultListFilter.folderName(record).isEmpty {
                    GroupTag(name: VaultListFilter.folderName(record)).padding(.top, 4)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if record.favorite { Image(systemName: "star.fill").font(.system(size: 18)).foregroundStyle(Color.accentColor).accessibilityLabel("Favorites") }
            if let selection, !selection.selecting, !record.isTotp {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Assigns the selected password entries to one group, or clears it. A group every selected entry is in shows a check, one only some are in a dash; tapping assigns it to all of them, or clears it when all already have it.
struct GroupAssignSheet: View {
    @EnvironmentObject var model: VaultModel
    @Environment(\.dismiss) private var dismiss
    let ids: Set<String>
    let done: () -> Void
    @State private var newGroup = ""
    private var targets: [VaultRecord] { model.records.filter { ids.contains($0.id) && VaultTab.passwords.contains($0) } }
    private var groups: [String] { VaultListFilter.folders(in: model.records) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New group", text: $newGroup).submitLabel(.done).onSubmit(addNew)
                        Button("Add", action: addNew).disabled(newGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    ForEach(groups, id: \.self) { name in
                        let inGroup = targets.filter { VaultListFilter.folderName($0) == name }.count
                        Button { assign(inGroup == targets.count ? "" : name) } label: {
                            HStack {
                                GroupTag(name: name)
                                Spacer()
                                if inGroup == targets.count { Image(systemName: "checkmark") }
                                else if inGroup > 0 { Image(systemName: "minus") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(localizedFormat(targets.count == 1 ? "Group %lld entry" : "Group %lld entries", targets.count)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func addNew() {
        let name = newGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { assign(name) }
    }
    private func assign(_ group: String) {
        let now = ISO8601DateFormatter().string(from: Date())
        let targetIDs = Set(targets.map(\.id))
        let updated = model.records.map { record -> VaultRecord in
            guard targetIDs.contains(record.id), record.group != group else { return record }
            var changed = record; changed.group = group; changed.updatedAt = now; return changed
        }
        model.run({ try $0.save(updated); return updated }, done: { done(); dismiss() })
    }
}
