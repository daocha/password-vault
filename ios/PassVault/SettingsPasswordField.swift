import SwiftUI
import UIKit

/// Keep the secure field and its initial keyboard focus in the presented sheet's UIKit hierarchy.
/// A FocusState owned by the presenting settings view can leave a nested sheet unfocused.
struct SettingsPasswordField: UIViewControllerRepresentable {
    @Binding var text: String

    func makeUIViewController(context: Context) -> Controller { Controller(text: $text) }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.text = $text
        controller.field.isEnabled = context.environment.isEnabled
        if controller.field.text != text { controller.field.text = text }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.field.resignFirstResponder()
        controller.field.text = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(34, uiViewController.field.intrinsicContentSize.height))
    }

    final class Controller: UIViewController {
        let field = Field()
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            field.isSecureTextEntry = true
            field.textContentType = .password
            field.placeholder = localized("Current app password")
            field.accessibilityLabel = localized("Current app password")
            field.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15))
            field.adjustsFontForContentSizeCategory = true
            field.textColor = .label
            field.backgroundColor = .clear
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.text = text.wrappedValue
            field.addTarget(self, action: #selector(edited), for: .editingChanged)
            view = field
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            field.becomeFirstResponder()
        }

        @objc private func edited() { text.wrappedValue = field.text ?? "" }
    }

    final class Field: UITextField {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let attachedWindow = window else { return }
            // Form cells can attach independently of their controller's appearance forwarding.
            DispatchQueue.main.async { [weak self, weak attachedWindow] in
                guard let self, let attachedWindow,
                      self.window === attachedWindow, attachedWindow.isKeyWindow else { return }
                self.becomeFirstResponder()
            }
        }
    }
}
