"""Cambios minimos en el codigo de Telegram-iOS para SFS App. Falla si algo no esta donde se espera."""
import json
import os
import sys

TG = sys.argv[1]


def patch(relative_path, old, new, count=1):
    path = os.path.join(TG, relative_path)
    with open(path, encoding='utf-8') as f:
        text = f.read()
    found = text.count(old)
    if found != count:
        sys.exit(f'ERROR: en {relative_path} esperaba {count} coincidencia(s) y encontre {found}:\n{old}')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text.replace(old, new))
    print(f'  ok: {relative_path}')


# 1. Nombre de la app (Telegram pide que los clientes no oficiales no usen su nombre)
patch('Telegram/BUILD',
      '    <key>CFBundleDisplayName</key>\n    <string>Telegram</string>\n',
      '    <key>CFBundleDisplayName</key>\n    <string>SFS App</string>\n',
      count=2)

for lang in ('ko', 'ar'):
    strings_path = f'Telegram/Telegram-iOS/{lang}.lproj/InfoPlist.strings'
    full = os.path.join(TG, strings_path)
    with open(full, encoding='utf-8') as f:
        lines = f.read().splitlines()
    kept = [line for line in lines if not line.strip().startswith('"CFBundleDisplayName"')]
    if len(kept) == len(lines):
        sys.exit(f'ERROR: no encontre CFBundleDisplayName en {strings_path}')
    with open(full, 'w', encoding='utf-8') as f:
        f.write('\n'.join(kept) + '\n')
    print(f'  ok: {strings_path}')

# 2. Colores del icono (degradado azul -> morado de SFS App)
icon_path = os.path.join(TG, 'Telegram/Telegram-iOS/Telegram.icon/icon.json')
with open(icon_path, encoding='utf-8') as f:
    icon_text = f.read()
replacements = [
    ('display-p3:0.21569,0.68627,0.89020,1.00000', 'srgb:0.23137,0.50980,0.96471,1.00000'),
    ('srgb:0.11373,0.57647,0.82353,1.00000', 'srgb:0.48627,0.22745,0.92941,1.00000'),
    ('srgb:0.00000,0.47843,1.00000,1.00000', 'srgb:0.48627,0.22745,0.92941,1.00000'),
]
for old, new in replacements:
    if icon_text.count(old) != 1:
        sys.exit(f'ERROR: color {old} no esta una sola vez en icon.json')
    icon_text = icon_text.replace(old, new)
json.loads(icon_text)
with open(icon_path, 'w', encoding='utf-8') as f:
    f.write(icon_text)
print('  ok: icon.json')

# 3. TelegramUI depende del modulo SFS
patch('submodules/TelegramUI/BUILD',
      '        "//third-party/recaptcha:RecaptchaEnterprise",\n',
      '        "//third-party/recaptcha:RecaptchaEnterprise",\n        "//submodules/SFSModule:SFSModule",\n')

# 4. El SFS trabaja en todas las cuentas con sesion iniciada: Telegram le pasa la lista cada vez que cambia
patch('submodules/TelegramUI/Sources/AppDelegate.swift',
      'import MTProtoRustEngine\n',
      'import MTProtoRustEngine\nimport SFSModule\n')

patch('submodules/TelegramUI/Sources/AppDelegate.swift',
      '''            let sharedApplicationContext = SharedApplicationContext(sharedContext: sharedContext, notificationManager: notificationManager, wakeupManager: wakeupManager)
''',
      '''            let sharedApplicationContext = SharedApplicationContext(sharedContext: sharedContext, notificationManager: notificationManager, wakeupManager: wakeupManager)
            
            let _ = (sharedContext.activeAccountContexts
            |> deliverOnMainQueue).start(next: { primary, accounts, _ in
                SFSModule.shared.updateAccounts(accounts.map { $0.1.account }, primaryAccount: primary?.account)
            })
''')

# 5. TelegramCore avisa al SFS de cada mensaje nuevo, tambien en chats silenciados
#    (`notificationMessages` los descarta)
STATE_MANAGER = 'submodules/TelegramCore/Sources/State/AccountStateManager.swift'
patch(STATE_MANAGER,
      '''        fileprivate let storyUpdatesPipe = ValuePipe<[InternalStoryUpdate]>()
''',
      '''        fileprivate let storyUpdatesPipe = ValuePipe<[InternalStoryUpdate]>()
        fileprivate let sfsIncomingMessageIdsPipe = ValuePipe<[MessageId]>()
''')

patch(STATE_MANAGER,
      '''                            if !events.storyUpdates.isEmpty {
                                strongSelf.storyUpdatesPipe.putNext(events.storyUpdates)
                            }
''',
      '''                            if !events.storyUpdates.isEmpty {
                                strongSelf.storyUpdatesPipe.putNext(events.storyUpdates)
                            }
                            if !events.addedIncomingMessageIds.isEmpty {
                                strongSelf.sfsIncomingMessageIdsPipe.putNext(events.addedIncomingMessageIds)
                            }
''')

patch(STATE_MANAGER,
      '''    func injectStoryUpdates(updates: [InternalStoryUpdate]) {
''',
      '''    var sfsIncomingMessageIds: Signal<[MessageId], NoError> {
        return self.impl.signalWith { impl, subscriber in
            return impl.sfsIncomingMessageIdsPipe.signal().start(next: subscriber.putNext)
        }
    }
    
    func injectStoryUpdates(updates: [InternalStoryUpdate]) {
''')

# 6. Telegram mantiene conectadas las cuentas con el SFS trabajando (no solo la abierta), y en segundo plano
#    las que tienen ese modo encendido
WAKEUP = 'submodules/TelegramUI/Sources/SharedWakeupManager.swift'
patch(WAKEUP,
      '''import TelegramAudio
''',
      '''import TelegramAudio
import SFSModule
''')

patch(WAKEUP,
      '''            strongSelf.hasActiveAudioSession = value
            strongSelf.checkTasks()
        })
''',
      '''            strongSelf.hasActiveAudioSession = value
            strongSelf.checkTasks()
        })
        
        let _ = NotificationCenter.default.addObserver(forName: SFSModule.keepAliveDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.checkTasks()
        })
''')

patch(WAKEUP,
      '''|| self.activeExplicitExtensionTimer != nil || self.silenceAudioRenderer != nil {
''',
      '''|| self.activeExplicitExtensionTimer != nil || self.silenceAudioRenderer != nil || SFSModule.shared.isKeepingAppAlive {
''')

patch(WAKEUP,
      '''                if (self.inForeground && primary) || !tasks.isEmpty || (self.activeExplicitExtensionTimer != nil && primary) {
''',
      '''                if (self.inForeground && primary) || !tasks.isEmpty || (self.activeExplicitExtensionTimer != nil && primary) || SFSModule.shared.shouldKeepConnection(userId: account.peerId.id._internalGetInt64Value(), isInForeground: self.inForeground) {
''')
