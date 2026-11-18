import SwiftUI
import UIKit

/// A password text field with an eye button beside it that shows or hides what was typed, as Android's `SecretInput` does. One UIKit
/// field switches between hidden and shown in place, so the field keeps its keyboard and its place on screen. Swapping a SecureField for
/// a TextField instead lost the keyboard and made the form jump. Starts hidden; the shown state belongs to this box only and is never saved.
final class PasswordBox: UIView {
    let field: UITextField
    let eye = UIButton(type: .system)

    init(field: UITextField = UITextField()) {
        self.field = field
        super.init(frame: .zero)
        field.isSecureTextEntry = true
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15))
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.backgroundColor = .clear
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        eye.tintColor = .secondaryLabel
        eye.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        eye.setContentHuggingPriority(.required, for: .horizontal)
        eye.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let row = UIStackView(arrangedSubviews: [field, eye])
        row.axis = .horizontal; row.spacing = 8; row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        setShown(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var shown: Bool { !field.isSecureTextEntry }
    @objc func toggle() { setShown(!shown) }

    func setShown(_ shown: Bool) {
        if self.shown != shown {
            field.isSecureTextEntry = !shown
            // A secure field that gets its text back while editing clears itself on the next key. Typing the text in again keeps it.
            if !shown, field.isFirstResponder, let existing = field.text, !existing.isEmpty {
                field.text = ""; field.insertText(existing)
            }
        }
        eye.setImage(UIImage(systemName: shown ? "eye.slash" : "eye"), for: .normal)
        eye.accessibilityLabel = localized(shown ? "Hide password" : "Show password")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: max(34, field.intrinsicContentSize.height)) }
}

/// `PasswordBox` for SwiftUI forms. `label` is a localization key, shown as the placeholder and read by VoiceOver.
struct PasswordInput: UIViewRepresentable {
    let label: String
    @Binding var text: String
    var contentType: UITextContentType? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> PasswordBox {
        let box = PasswordBox()
        box.field.placeholder = localized(label)
        box.field.accessibilityLabel = localized(label)
        box.field.textContentType = contentType
        box.field.text = text
        box.field.addTarget(context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
        return box
    }
    func updateUIView(_ box: PasswordBox, context: Context) {
        context.coordinator.text = $text
        box.field.isEnabled = context.environment.isEnabled
        if box.field.text != text { box.field.text = text }
    }
    static func dismantleUIView(_ box: PasswordBox, coordinator: Coordinator) {
        box.field.resignFirstResponder(); box.field.text = nil
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PasswordBox, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: uiView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        @objc func edited(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
    }
}
