# CHANGELOG - SFS App para iPhone (nativa)

## v0.7.0 - 2026-10-20
- Motor SFS nativo en Swift (`SFSModule/Sources/Core`), misma logica que la app de Windows y el bot:
  detecta la promo (foto con @/links, o foto y texto por separado, "sfs", "use"/"go"), manda aviso + ADS,
  sube a la historia con el texto y formato de la promo (emojis premium) y el @ al final, detecta cuando
  te publica (aviso de mencion o historia nueva), gracias 1 min despues + anuncio fijo, baja a quien no
  publica a tiempo (con una verificacion extra si no se puede confirmar), cuentas del sistema en silencio,
  cola de 20-40 s entre historias, perfil seguro de 13-30 s, historia llena (100) y anti-bucle.
- 21 pruebas automaticas del motor (`swift test`) que corren en GitHub antes de la compilacion larga.
- Puente con TelegramCore (`ios/TelegramCoreSFS/SFSBridge.swift`): ve los mensajes nuevos tambien en chats
  silenciados, sube las historias con el sistema nativo de Telegram (se ve la barra de "subiendo") y
  manda los mensajes y el ADS (copia sin "reenviado de") como mensajes normales.
- Panel completo: Inicio (encender/apagar, tu ADS desde Mensajes guardados, estadisticas, en curso,
  licencia), Mensajes (apagar/editar cada uno, anuncio fijo), Ajustes (duracion 6/12/24/48 h, tiempo
  para publicar, perfil seguro) y Actividad.
- Boton flotante: punto verde = trabajando, gris = apagado, rojo = sin licencia. Con el SFS trabajando
  la pantalla no se apaga.
- Cambio nuevo en Telegram-iOS: `AccountStateManager.swift` (3 lineas para avisar de mensajes nuevos).

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
