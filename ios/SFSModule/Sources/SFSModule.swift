import Foundation
import UIKit
import SwiftUI
import Combine
import SwiftSignalKit
import Postbox
import TelegramCore

// Punto de entrada del modulo SFS. Telegram (AuthorizedApplicationContext) llama `start` al iniciar sesion
// y `stop` al cerrar la sesion de esa cuenta.
public final class SFSModule {
    public static let shared = SFSModule()

    let license = SFSLicenseStore()
    @MainActor private var session: SFSSession?
    @MainActor private var floatingWindow: SFSFloatingWindow?

    private init() {
    }

    public func start(account: Account, username: String?, fullName: String?) {
        Task { @MainActor in
            self.startSession(account: account, username: username, fullName: fullName)
        }
    }

    public func stop(userId: Int64) {
        Task { @MainActor in
            self.stopSession(userId: userId)
        }
    }

    @MainActor
    private func startSession(account: Account, username: String?, fullName: String?) {
        let userId = account.peerId.id._internalGetInt64Value()
        if self.session?.userId == userId {
            return
        }
        self.session?.stop()

        self.license.start(userId: userId, username: username, fullName: fullName)
        let session = SFSSession(account: account, license: self.license)
        self.session = session
        self.showFloatingButton(session: session)
    }

    @MainActor
    private func stopSession(userId: Int64) {
        guard let session = self.session, session.userId == userId else {
            return
        }
        session.stop()
        self.session = nil
        self.license.stop()
        self.floatingWindow?.isHidden = true
        self.floatingWindow = nil
    }

    @MainActor
    private func showFloatingButton(session: SFSSession) {
        self.floatingWindow?.isHidden = true
        let window = SFSFloatingWindow(status: session.buttonStatus, onTap: { [weak self] in
            self?.presentPanel()
        })
        window.show()
        self.floatingWindow = window
    }

    @MainActor
    func presentPanel() {
        guard let session = self.session, let presenter = Self.topViewController(), !(presenter is SFSPanelHostingController) else {
            return
        }

        let controller = SFSPanelHostingController(license: self.license, session: session)
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(controller, animated: true)
    }

    @MainActor
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

// Todo lo del SFS de una cuenta con sesion iniciada
@MainActor
final class SFSSession {
    let userId: Int64
    let settings: SFSSettingsStore
    let state: SFSStateStore
    let engine: SFSEngine
    let telegram: SFSTelegramAdapter
    let buttonStatus: AnyPublisher<SFSButtonStatus, Never>

    private let disposables = DisposableSet()
    private var cancellables = Set<AnyCancellable>()
    private var isKeepingScreenAwake = false

    init(account: Account, license: SFSLicenseStore) {
        let storage = SFSUserDefaultsStorage()
        let userId = account.peerId.id._internalGetInt64Value()
        let settings = SFSSettingsStore(storage: storage)
        let state = SFSStateStore(storage: storage, now: { Date() })
        let telegram = SFSTelegramAdapter(account: account)
        let engine = SFSEngine(
            telegram: telegram,
            clock: SFSSystemClock(),
            settings: settings,
            state: state,
            isLicenseValid: { [weak license] in
                return license?.isValid ?? false
            }
        )
        self.userId = userId
        self.settings = settings
        self.state = state
        self.telegram = telegram
        self.engine = engine
        self.buttonStatus = license.$state
            .combineLatest(settings.$settings)
            .map { licenseState, settings -> SFSButtonStatus in
                switch licenseState {
                case .valid:
                    return settings.isEnabled ? .working : .off
                case .loading:
                    return .off
                case .invalid, .error:
                    return .noLicense
                }
            }
            .removeDuplicates()
            .eraseToAnyPublisher()

        engine.start(userId: userId)

        // Con el SFS trabajando la pantalla no se apaga (si se bloquea, iOS pausa la app y el SFS se detiene)
        self.buttonStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.setKeepScreenAwake(status == .working)
            }
            .store(in: &self.cancellables)

        self.disposables.add((SFSBridge.incomingMessages(account: account)
        |> deliverOnMainQueue).start(next: { [weak self] messages in
            guard let self = self else {
                return
            }
            for message in messages {
                self.engine.handleIncoming(SFSIncomingMessage(bridgeMessage: message))
            }
        }))

        self.disposables.add((SFSBridge.addedStories(account: account)
        |> deliverOnMainQueue).start(next: { [weak self] updates in
            guard let self = self else {
                return
            }
            for update in updates {
                self.engine.handleStoryUpdate(userId: update.userId, storyId: update.storyId)
            }
        }))
    }

    func stop() {
        self.disposables.dispose()
        self.cancellables.removeAll()
        self.engine.stop()
        self.setKeepScreenAwake(false)
    }

    private func setKeepScreenAwake(_ isAwake: Bool) {
        if self.isKeepingScreenAwake == isAwake {
            return
        }
        self.isKeepingScreenAwake = isAwake
        UIApplication.shared.isIdleTimerDisabled = isAwake
    }
}

final class SFSPanelHostingController: UIHostingController<SFSPanelView> {
    init(license: SFSLicenseStore, session: SFSSession) {
        var dismissAction: (() -> Void)?
        super.init(rootView: SFSPanelView(license: license, session: session, settings: session.settings, state: session.state, onClose: {
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
