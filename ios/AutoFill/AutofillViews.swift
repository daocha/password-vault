import SwiftUI
import VaultCore

/// The extension's screens, in the language and appearance chosen in PassVault.
struct AutofillRoot: View {
    @ObservedObject var model: AutofillModel
    var body: some View {
        let preferences = AutofillSettings.preferences
        NavigationStack {
            Group {
                switch model.stage {
                case .loading: ProgressView()
                case .unavailable(let text): UnavailableView(text: text)
                case .locked: AutofillUnlockView(model: model)
                case .open: AutofillPickView(model: model)
                }
            }
            .navigationTitle("Fill from PassVault").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() }.accessibilityIdentifier("autofill.cancel") } }
        }
        .environment(\.locale, preferences.language.locale)
        .preferredColorScheme(preferences.theme == .light ? .light : preferences.theme == .dark ? .dark : nil)
        .tint(Color(light: 0x244E87, dark: 0xA9C7FF))
    }
}

private extension Color {
    /// The app's brand blue, as `Color.aPrimary` in the app.
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private struct UnavailableView: View {
    let text: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.trianglebadge.exclamationmark").font(.system(size: 44)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).multilineTextAlignment(.center)
        }.padding(32)
    }
}

private struct AutofillHeader: View {
    let target: String
    var body: some View {
        VStack(spacing: 8) {
            Image("vault_icon").resizable().scaledToFit().frame(width: 72, height: 72).accessibilityHidden(true)
            Text("Unlock PassVault to fill").font(.title3.bold()).multilineTextAlignment(.center)
            Text(localizedFormat("For %@", target)).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

struct AutofillUnlockView: View {
    @ObservedObject var model: AutofillModel
    @State private var password = ""
    var body: some View {
        Form {
            Section { AutofillHeader(target: model.target) }.listRowBackground(Color.clear)
            Section {
                // No content type: iOS must not offer saved passwords for PassVault's own password here.
                PasswordInput(label: "App password", text: $password)
                Button("Unlock vault") { let value = password; password = ""; model.unlock(password: value) }
                    .disabled(password.isEmpty || model.busy)
                if model.biometricEnabled {
                    Button("Unlock with Face ID / Touch ID", systemImage: "faceid") { model.unlockWithBiometrics() }.disabled(model.busy)
                }
            } footer: { Text(localizedFormat("%lld password attempts remaining", model.attempts)) }
            if !model.message.isEmpty {
                Section { Label(model.message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red) }
            }
        }
        .overlay { if model.busy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .onDisappear { password = "" }
    }
}

struct AutofillPickView: View {
    @ObservedObject var model: AutofillModel
    @State private var query = ""
    var body: some View {
        let shown = AutofillMatch.shown(model.logins, sites: model.sites, query: query)
        List {
            Section {
                if shown.records.isEmpty {
                    Text(LocalizedStringKey(model.logins.isEmpty ? "No logins with a username or password yet." : "No logins match your search.")).foregroundStyle(.secondary)
                }
                ForEach(shown.records) { record in
                    Button { model.confirming = record } label: { LoginRow(record: record) }.buttonStyle(.plain)
                }
            } header: {
                Text(LocalizedStringKey(!query.trimmingCharacters(in: .whitespaces).isEmpty ? "Search" : shown.suggested ? "Suggested" : "All logins"))
            } footer: {
                if query.trimmingCharacters(in: .whitespaces).isEmpty && !shown.suggested && !model.logins.isEmpty {
                    Text("No login is saved for this app or site. Pick one or search.")
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .autocorrectionDisabled()
        // Matching a website only puts a login first: the user always confirms where it goes, as on Android.
        .alert("Fill this login?", isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }), presenting: model.confirming) { record in
            Button("Fill") { model.fill(record) }
            Button("Cancel", role: .cancel) { model.confirming = nil }
        } message: { record in
            Text(localizedFormat("“%@” will be filled in:\n%@\n\nFill it only if this is the site or app you meant to sign in to.", title(record), model.target))
        }
    }
    private func title(_ record: VaultRecord) -> String { record.name.isEmpty ? record.website : record.name }
}

private struct LoginRow: View {
    let record: VaultRecord
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name.isEmpty ? record.website : record.name).font(.body).lineLimit(1)
                if let detail = AutofillMatch.username(record) ?? (record.website.isEmpty ? nil : record.website) {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if record.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).accessibilityLabel("Favorite") }
        }.contentShape(Rectangle())
    }
}
