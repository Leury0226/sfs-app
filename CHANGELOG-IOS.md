# CHANGELOG - SFS App para iPhone (nativa)

## v0.6.0 - 2026-10-20
- Nombre "SFS App" e icono propio (flechas + SFS, degradado azul a morado), sin el nombre ni el logo de Telegram.
- Modulo SFS (`ios/SFSModule`, Swift): arranca al iniciar sesion y se apaga al cerrar esa sesion.
- Boton flotante SFS estilo AssistiveTouch: ventana propia del tamaño del boton (no toca la interfaz de Telegram
  ni la barra de estado), se arrastra y se pega al borde, recuerda la posicion. Punto rojo = sin licencia.
- Panel SFS nativo (SwiftUI, hoja deslizable): licencia contra followmytg.com (consulta, canje de clave,
  12 h sin conexion con la ultima licencia valida, revision cada hora), precios y contacto.
- Cambios en Telegram-iOS: solo `Telegram/BUILD` (nombre), icono, `TelegramUI/BUILD` (dependencia) y
  2 lineas en `ApplicationContext.swift` (arrancar/apagar). Los aplica `ios/apply.sh`, que se detiene si
  Telegram cambia esas partes.

## v0.0.1 - 2026-10-20
- Fase 0: Telegram oficial para iPhone (commit f1dd7a2) compilado en GitHub con la configuracion de SFS App.
