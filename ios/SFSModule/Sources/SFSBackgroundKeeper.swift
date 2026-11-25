import Foundation
import AVFoundation
import UIKit

// Modo segundo plano: mientras la app no esta en pantalla toca audio en silencio (mezclado con otras apps,
// sin sonido) para que iOS no la congele y el SFS siga trabajando. En pantalla no toca nada, asi no se mete
// con los audios y llamadas de Telegram.
@MainActor
final class SFSBackgroundKeeper {
    // Cada cuanto se revisa que el audio siga sonando (Telegram puede apagar la sesion de audio al terminar un audio suyo)
    private static let checkInterval: TimeInterval = 20
    private static let silenceSampleRate = 8000

    private var isEnabled = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            AVAudioSession.interruptionNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]
        for name in names {
            self.observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.update()
                }
            })
        }
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        if self.isEnabled == isEnabled {
            return
        }
        self.isEnabled = isEnabled
        self.update()
    }

    private func update() {
        if self.isEnabled && UIApplication.shared.applicationState == .background {
            self.startPlaying()
        } else {
            self.stopPlaying()
        }
    }

    private func startPlaying() {
        let session = AVAudioSession.sharedInstance()
        // En llamada o grabando audio la sesion es de Telegram: no se le cambia
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)

        if self.player == nil {
            let player = try? AVAudioPlayer(data: Self.makeSilence())
            player?.numberOfLoops = -1
            player?.volume = 0
            self.player = player
        }
        if self.player?.isPlaying != true {
            self.player?.play()
        }

        if self.timer == nil {
            self.timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.update()
                }
            }
        }
    }

    private func stopPlaying() {
        self.timer?.invalidate()
        self.timer = nil
        self.player?.stop()
        self.player = nil
    }

    // Un segundo de silencio en WAV (PCM 16 bits, mono)
    private static func makeSilence() -> Data {
        let bytesPerSample = 2
        let dataSize = self.silenceSampleRate * bytesPerSample
        var data = Data()

        func append(_ text: String) {
            data.append(contentsOf: Array(text.utf8))
        }
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(self.silenceSampleRate))
        append(UInt32(self.silenceSampleRate * bytesPerSample))
        append(UInt16(bytesPerSample))
        append(UInt16(16))
        append("data")
        append(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
