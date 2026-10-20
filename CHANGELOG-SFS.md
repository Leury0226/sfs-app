# CHANGELOG - SFS App

SFS App es una version modificada de Telegram Web A (https://github.com/Ajaxy/telegram-tt, GPL v3)
con un modulo SFS integrado. Todo el codigo propio esta en `src/sfs/` (web) e `ios/` (iPhone).

## v0.5.0 - 2026-10-19
### Añadido
- Boton flotante "SFS" (estilo AssistiveTouch): abre el panel SFS, se arrastra a cualquier borde y recuerda
  la posicion. Color segun el estado: azul con punto verde = SFS encendido, gris = apagado, punto rojo = sin licencia.
- Barra de abajo estilo Telegram para iPhone en pantallas de movil: Contactos · Chats (con no leidos) · Ajustes.
  Las listas dejan espacio abajo y el lapiz de nuevo mensaje sube para no quedar tapado.

### Arreglado
- iPhone: la interfaz quedaba debajo de la isla y la hora. Ahora va dentro del area segura, y las franjas de
  arriba y abajo toman el color del tema (claro u oscuro), igual que la barra de estado.

## v0.4.0 - 2026-10-19
### Añadido
- App de iPhone (`ios/`): app nativa minima en Swift que carga la misma interfaz (Telegram + SFS) en un WebView.
  Sirve la interfaz desde la propia app (sfsapp://localhost), abre los links externos en Safari y pide
  permisos de camara, microfono y fotos.
- Workflow `.github/workflows/ios.yml`: compila el .ipa sin firmar en una Mac de GitHub (con las pruebas
  del motor SFS antes de compilar). Usa los secretos TELEGRAM_API_ID y TELEGRAM_API_HASH.
- En iPhone, mientras el SFS esta encendido, la pantalla no se apaga sola (iOS congela las apps que no
  estan en pantalla). El panel avisa de esto.
- Icono provisional "SFS" (sin el logo de Telegram).
- Prueba nueva del puente con iPhone (19 pruebas en total).

### Quitado
- `.github/workflows/package-and-publish.yml` (era el despliegue de Telegram, no aplica a SFS App).


## v0.3.0 - 2026-10-18
Fase 3: motor SFS (el ciclo completo, portado del bot del servidor v1.0.91).

### Añadido
- Motor SFS dentro de la app: corre con la cuenta y la IP del cliente.
  - Detecta la promo igual que el bot (`is_sfs_message`, `is_sfs_with_photo`): foto con @ o link,
    foto y texto en 2 mensajes, "use"/"go", y "sfs" sin foto (pide el spam).
  - Manda el aviso de tiempo + tu ADS (copia de un mensaje de tus Mensajes guardados: conserva foto y
    emojis premium), espera 13-30s al azar antes (perfil seguro).
  - Sube la promo a tu historia conservando texto, formato y emojis premium, y agrega el @ de la persona.
    Cola de publicacion con 20-40s entre historias. Respeta el limite de 100 historias.
  - Detecta cuando te publican (aviso de mencion de Telegram o historia nueva de alguien en SFS) y guarda
    el ID de su historia.
  - Te publico primero: lo sube con su ultima foto del chat, o le pide la foto.
  - SFS completo: 1 minuto despues manda el gracias (8 variantes al azar) y tu anuncio de SFS Story Bot.
  - Si no te publica a tiempo (60 min por defecto), lo baja de tu historia. Antes verifica en vivo.
  - Al vencer (24h por defecto) el SFS termina y se puede volver a hacer con esa persona.
  - Reconoce otras cuentas del sistema (marca invisible): sin gracias ni pedidos, con desfase de tiempo.
- Panel SFS con pestañas: Inicio (encender/apagar, contadores, quien esta en tu historia, ADS),
  Mensajes, Ajustes y Actividad.
- Cada mensaje (aviso de tiempo, gracias, pedir spam, te publico sin foto, error al subir) tiene su
  interruptor y su texto editable, con boton para restaurar el original. El ADS tambien se puede apagar.
- El anuncio de SFS Story Bot se manda siempre al completar un SFS: el cliente no lo puede apagar ni editar.
  Es copia exacta de `get_promo_message()` del bot.
- `4-PROBAR-MOTOR-SFS.bat`: 18 pruebas automaticas del motor (simulacion, no toca la cuenta).

### Diferencias con el bot del servidor (a proposito)
- Una historia nueva cuenta como "te publico" solo si de verdad te menciona (el bot aceptaba cualquier
  historia). Evita guardar un ID equivocado que despues daria traiciones falsas.
- Si alguien que bajaste por no publicar te publica despues, se vuelve a subir (el bot solo lo marcaba).
- Si no se puede confirmar si te publico (muchas historias), se le dan 10 min mas una sola vez antes de bajarlo.
- SFS en 2 mensajes: la historia usa el texto de la promo con su formato (el bot lo perdia).
- Apagado = no empieza SFS nuevos, pero termina los que estan en curso (gracias y bajadas), como "pausado".
- No se puede encender sin ADS configurado (o con el ADS apagado).
- Los delays anti-baneo son fijos (perfil seguro). Duracion y tiempo para publicar si se editan.

### Arreglado
- Los .bat avisan si se abren desde la carpeta de la actualizacion en vez de la del proyecto.
- La actualizacion hace que git ignore `tauri/target` (la carpeta pesada de compilacion).

### Pendiente (proximas versiones)
- Traiciones, SFS fijos, Mis historias, lista negra.

## v0.2.0 - 2026-10-17
- Fase 2: boton "SFS" en el menu lateral que abre el panel del modulo SFS.
- Licencias: al abrir la app se consulta /client/status con el ID de Telegram de la cuenta;
  se vuelve a consultar cada 1 hora.
- Sin licencia: el panel queda bloqueado, permite canjear una clave (/client/redeem),
  muestra precios y contacto. Telegram funciona normal.
- Sin internet: si hubo una licencia valida verificada en las ultimas 12 horas, se sigue usando.
- Codigo propio separado en `src/sfs/` (config, licencia, panel); solo se tocaron 2 archivos
  de Telegram Web A: `LeftSideMenuItems.tsx` (boton) y `Main.tsx` (montar el panel).
- La version de la app ahora es la nuestra (0.2.0) y no la de Telegram Web A.
- Los .bat de prueba liberan el puerto 1234 solos antes de arrancar.
- Nota: al cerrar la ventana, la app queda en la bandeja (junto al reloj). Para salir: clic derecho al icono.

## v0.1.0 - 2026-10-17
- Fase 1: base de Telegram Web A (commit f67a408) empaquetada con Tauri para Windows.
- Herramientas portables (Node, Git, Rust) dentro de la carpeta SFS-Telegram-App.
- Config propia `tauri/tauri.sfs.json`: nombre "SFS App", id com.followmytg.sfsapp,
  la interfaz va empaquetada dentro del .exe (el original abria una URL externa).
- Scripts: probar en navegador, probar app de escritorio, crear instalador.
