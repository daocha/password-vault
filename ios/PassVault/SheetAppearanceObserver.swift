import SwiftUI
import UIKit

/// SwiftUI tasks can run before a sheet's fields are attached to a presented window.
/// Use UIKit's completed appearance callback for work such as requesting keyboard focus.
struct SheetAppearanceObserver: UIViewControllerRepresentable {
    var appeared: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(appeared: appeared) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.appeared = appeared }

    final class Controller: UIViewController {
        var appeared: () -> Void

        init(appeared: @escaping () -> Void) {
            self.appeared = appeared
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Apply SwiftUI focus on the next update, after the presentation has settled.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.appeared()
            }
        }
    }
}
