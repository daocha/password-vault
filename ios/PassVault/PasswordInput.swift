import SwiftUI

/// A password box with an eye button that shows or hides what was typed, as Android's `SecretInput` does. It starts hidden, and the
/// shown state belongs to this box only and is never saved. The box keeps the keyboard when the eye is tapped.
struct PasswordInput: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var contentType: UITextContentType? = nil
    @State private var shown = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if shown { TextField(label, text: $text) } else { SecureField(label, text: $text) }
            }
            .font(.system(size: 15)).textContentType(contentType).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
            Button {
                let hadFocus = focused
                shown.toggle()
                // The box is replaced by the other kind; give the new one the keyboard once it exists.
                if hadFocus { DispatchQueue.main.async { focused = true } }
            } label: {
                Image(systemName: shown ? "eye.slash" : "eye").foregroundStyle(Color.aOnSurfaceVariant).frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).accessibilityLabel(Text(LocalizedStringKey(shown ? "Hide password" : "Show password")))
        }
    }
}
