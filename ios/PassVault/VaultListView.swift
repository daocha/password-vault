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
    @State private var editingTotp: VaultRecord?
    @State private var viewingSeed: VaultRecord?
    @State private var editingSeed: VaultRecord?
    @State private var seedDeletion: Set<String>?
    @State private var reordering = false
    @State private var transfer = false
    @State private var health = false
    @State private var healthFocus: String?
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
                vaultToolbar
                listControls
                List {
                    notices
                    if tabRecords.isEmpty { emptyState.listRowBackground(Color.clear) }
                    ForEach(filtered) { record in
                        Button {
                            if record.isTotp { editingTotp = record }
                            else if record.isSeed { viewingSeed = record }
                            else { editing = record }
                        } label: {
                            Group {
                                if record.isTotp { TotpRow(record: record) }
                                else { VaultEntryRow(record: record) }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                            .contentShape(RoundedRectangle(cornerRadius: 16))
                        }
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
                addEntryButton.buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16)).controlSize(.large).padding(16)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: searchOpen) { _, open in if open { searchFocused = true } }
            .onChange(of: tab) { _, _ in query = ""; folder = nil; kind = nil }
            .onChange(of: folders) { _, names in if let folder, !names.contains(folder) { self.folder = nil } }
            .onChange(of: kinds) { _, names in if let kind, !names.contains(kind) { self.kind = nil } }
            .sheet(item: $editing) { RecordEditor(record: $0) }
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
            Picker("Show", selection: $tab) {
                ForEach(VaultTab.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }.pickerStyle(.segmented)
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
            }
            if !tabRecords.isEmpty {
                HStack {
                    Text(localizedFormat(showTotp ? "%lld of %lld codes" : tab == .seed ? "%lld of %lld seed phrases" : "%lld of %lld entries", filtered.count, tabRecords.count))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if showTotp && tabRecords.count > 1 {
                        Button {
                            searchOpen = false; searchFocused = false; reordering = true
                        } label: { Label("Reorder", systemImage: "arrow.up.arrow.down") }
                        .font(.callout.weight(.medium)).accessibilityIdentifier("totp-reorder-button")
                    }
                }.frame(minHeight: 24)
            }
        }.padding(.horizontal, 16).padding(.bottom, 4)
    }
    @ViewBuilder private var notices: some View {
        if model.backupDue {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.lastBackup.map { localizedFormat("Last backup %@ · %lld entries changed since", $0.formatted(.relative(presentation: .named)), BackupReminder.changedSince(model.records, lastBackup: $0)) }
                      ?? localized("No backup yet. If this phone is lost or reset, these entries are gone."), systemImage: "externaldrive.badge.exclamationmark").font(.caption)
                HStack { Button("Back up") { transfer = true }; Spacer(); Button("Later") { model.snoozeBackup() }.foregroundStyle(.secondary) }.buttonStyle(.borderless)
            }.padding(.vertical, 4).listRowSeparator(.hidden)
        }
        let expiring = model.records.filter { $0.needsNotice() }.count
        if expiring > 0 {
            Button { healthFocus = "expiring"; health = true } label: {
                HStack { Label("Expired or due within 14 days: \(expiring)", systemImage: "calendar.badge.exclamationmark").lineLimit(1); Spacer(); Text("Review") }.font(.footnote)
            }.listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)).listRowSeparator(.hidden)
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

/// Material's titleMedium/bodyMedium sizes, weights and line heights, scaled for Accessibility.
struct VaultEntryRow: View {
    let record: VaultRecord
    var showsStatus = true
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
            RecordIcon(record: record).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 0) {
                Text(record.name.isEmpty ? localized("Untitled record") : record.name)
                    .font(.system(size: titleSize, weight: .medium)).foregroundStyle(.primary)
                    .lineLimit(textSize.isAccessibilitySize ? 2 : 1).frame(minHeight: titleHeight, alignment: .leading)
                if !subtitle.isEmpty { Text(verbatim: subtitle).font(.system(size: subtitleSize)).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? 2 : 1).frame(minHeight: subtitleHeight, alignment: .leading) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showsStatus { VStack(alignment: .trailing, spacing: 4) {
                if VaultTab.passwords.contains(record) && !VaultListFilter.folderName(record).isEmpty {
                    GroupTag(name: VaultListFilter.folderName(record)).frame(maxWidth: 120, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
                }
                ExpiryBadge(record: record)
            } }
        }
    }
}
