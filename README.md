# SFS App para iPhone (nativa)

Telegram oficial para iPhone ([Telegram-iOS](https://github.com/TelegramMessenger/Telegram-iOS), GPL v2)
con el modulo SFS integrado. Este repo no copia todo Telegram-iOS: el workflow `.github/workflows/ios-nativo.yml`
baja la version fijada (`TELEGRAM_IOS_COMMIT`), le aplica los cambios de `ios/` y compila el .ipa.

- Secretos necesarios: `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`.
- El .ipa sale firmado con el certificado de prueba de Telegram; se firma de nuevo con Sideloadly o SideStore.
- Registro de cada compilacion: rama `ci-logs`.
