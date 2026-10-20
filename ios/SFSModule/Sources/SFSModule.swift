import Foundation
import UIKit
import SwiftUI

// Punto de entrada del modulo SFS. Telegram (AuthorizedApplicationContext) llama `start` al iniciar sesion
// y `stop` al cerrar la sesion de esa cuenta.
public final class SFSModule {
    public static let shared = SFSModule()

    let license = SFSLicenseStore()
    private var floatingWindow: SFSFloatingWindow?

    private init() {
    }

    public func start(userId: Int64, username: String?, fullName: String?) {
        self.license.start(userId: userId, username: username, fullName: fullName)
        self.showFloatingButton()
    }

    public func stop(userId: Int64) {
        guard self.license.userId == userId else {
            return
        }
        self.license.stop()
        self.floatingWindow?.isHidden = true
        self.floatingWindow = nil
    }

    private func showFloatingButton() {
        if self.floatingWindow != nil {
            return
        }
        let window = SFSFloatingWindow(license: self.license, onTap: { [weak self] in
            self?.presentPanel()
        })
        window.show()
        self.floatingWindow = window
    }

    func presentPanel() {
        guard let presenter = Self.topViewController(), !(presenter is SFSPanelHostingController) else {
            return
        }

        let controller = SFSPanelHostingController(license: self.license)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !($0 is SFSFloatingWindow) && !$0.isHidden }
        let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

final class SFSPanelHostingController: UIHostingController<SFSPanelView> {
    init(license: SFSLicenseStore) {
        var dismissAction: (() -> Void)?
        super.init(rootView: SFSPanelView(license: license, onClose: {
            dismissAction?()
        }))
        dismissAction = { [weak self] in
            self?.dismiss(animated: true)
        }
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
