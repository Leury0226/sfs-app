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
