import SwiftUI
import UIKit
import VaultCore

/// Update the native text and cursor together: a computed SwiftUI binding can leave UITextField's
/// editing buffer showing the unformatted input when its setter strips the inserted separators.
struct TransferCodeField: UIViewRepresentable {
    @Binding var code: String

    func makeCoordinator() -> Coordinator { Coordinator(code: $code) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = localized("Transfer code")
        field.accessibilityIdentifier = "transfer.code"
        field.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        field.adjustsFontForContentSizeCategory = true
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        if #available(iOS 18.0, *) { field.writingToolsBehavior = .none }
        field.keyboardType = .asciiCapable
        field.delegate = context.coordinator
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.code = $code
        let shown = Transfer.typingShown(code)
        if field.text != shown { field.text = shown }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var code: Binding<String>
        init(code: Binding<String>) { self.code = code }

        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            let old = (field.text ?? "") as NSString
            var editedRange = range
            // Backspacing an automatic separator removes the preceding character, even in the middle.
            if string.isEmpty, range.length == 1, range.location > 0, old.substring(with: range) == "-" {
                editedRange = NSRange(location: range.location - 1, length: 2)
            }
            let edited = old.replacingCharacters(in: editedRange, with: string)
            let kept = Transfer.typing(edited)
            let prefix = (old.substring(to: editedRange.location) + string)
            let beforeCursor = min(Transfer.typing(prefix).count, kept.count)
            let shown = Transfer.typingShown(kept)
            field.text = shown
            if let position = field.position(from: field.beginningOfDocument, offset: min(beforeCursor + min(beforeCursor / 4, 2), shown.count)) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
            code.wrappedValue = kept
            return false
        }
    }
}
