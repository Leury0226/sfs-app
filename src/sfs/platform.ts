// Puente con la app nativa de iPhone (`ios/`). En escritorio no existe y todo esto no hace nada
type NativeBridge = { postMessage: (message: unknown) => void };

function getIosBridge() {
  return (window as { webkit?: { messageHandlers?: { sfsNative?: NativeBridge } } })
    .webkit?.messageHandlers?.sfsNative;
}

export const IS_SFS_IOS_APP = Boolean(getIosBridge());

// En iPhone el SFS solo trabaja con la app en pantalla: mientras este encendido, la pantalla no se apaga sola
export function setKeepScreenAwake(isAwake: boolean) {
  getIosBridge()?.postMessage({ keepAwake: isAwake });
}

// La franja de la barra de estado (arriba) y la del indicador de inicio (abajo) las pinta la app nativa:
// se le pasa el color del tema cada vez que cambia entre claro y oscuro
function syncNativeTheme() {
  const root = document.documentElement;
  const background = getComputedStyle(root).getPropertyValue('--color-background').trim();
  if (!background) return;

  getIosBridge()?.postMessage({ theme: { background, isDark: root.classList.contains('theme-dark') } });
}

if (IS_SFS_IOS_APP) {
  new MutationObserver(syncNativeTheme).observe(document.documentElement, {
    attributes: true, attributeFilter: ['class', 'style'],
  });
  window.addEventListener('load', syncNativeTheme);
  syncNativeTheme();
}
