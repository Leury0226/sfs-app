import { createStore, get, set } from 'idb-keyval';

import { createSignal } from '../util/signals';

export const SFS_DURATION_OPTIONS = [6, 12, 24, 48] as const;
export type SfsDurationHours = typeof SFS_DURATION_OPTIONS[number];

export const SFS_PUBLISH_TIMEOUT_MAX = 240;

export type SfsMessageKey = 'avisoTiempo' | 'gracias' | 'pedirSpam' | 'pedirFotoPublicado' | 'errorSubir';

export type SfsMessageSetting = {
  isEnabled: boolean;
  text: string;
};

export type SfsSettings = {
  isEnabled: boolean;
  durationHours: SfsDurationHours;
  publishTimeoutMin: number;
  messages: Record<SfsMessageKey, SfsMessageSetting>;
  ads: {
    isEnabled: boolean;
    savedMessageId?: number;
    preview?: string;
    hasPhoto?: boolean;
  };
};

export const SFS_MESSAGE_INFO: Record<SfsMessageKey, { title: string; description: string }> = {
  avisoTiempo: {
    title: 'Aviso de tiempo',
    description: 'Se manda justo antes de tu ADS, cuando subes a alguien.',
  },
  gracias: {
    title: 'Gracias',
    description: 'Un minuto después de completar el SFS. Una variante por línea: se elige una al azar.',
  },
  pedirSpam: {
    title: 'Pedir su spam',
    description: 'Cuando alguien escribe "sfs" sin mandar su foto.',
  },
  pedirFotoPublicado: {
    title: 'Te publicó sin foto',
    description: 'Cuando alguien te publica primero pero no tiene foto en el chat.',
  },
  errorSubir: {
    title: 'Error al subir',
    description: 'Si Telegram no deja publicar la historia.',
  },
};

export const SFS_MESSAGE_KEYS = Object.keys(SFS_MESSAGE_INFO) as SfsMessageKey[];

// Textos que manda el bot del servidor (`sfs_flow.py`). Variables: {horas}, {minutos}
export const DEFAULT_SFS_SETTINGS: SfsSettings = {
  isEnabled: false,
  durationHours: 24,
  // Perfil seguro del bot del servidor
  publishTimeoutMin: 60,
  messages: {
    avisoTiempo: {
      isEnabled: true,
      text: '✅ Te subí a mi historia por {horas}h. Súbeme tú también 🙌',
    },
    gracias: {
      isEnabled: true,
      // `THANKS_VARIANTS`: mismo significado, distinto texto, para no repetir siempre el mismo mensaje
      text: [
        '¡Gracias por el SFS! 🤝 Te tengo arriba por {horas}h.',
        '¡Listo! SFS completo ✅ Ambos publicados por {horas}h. 🙌',
        '¡Perfecto! Ya estamos los dos arriba por {horas}h. 🔄',
        '¡Hecho! 🤝 Gracias por el intercambio, es por {horas}h.',
        '¡Genial! SFS confirmado ✅ Nos tenemos {horas}h. 🙌',
        '¡Excelente! Ya te tengo en mi historia {horas}h. Gracias 🤝',
        '¡Todo listo! 🔄 Intercambio hecho por {horas}h. 🙌',
        '¡Gracias! 🙌 Ambos publicados, válido por {horas}h. ✅',
      ].join('\n'),
    },
    pedirSpam: {
      isEnabled: true,
      text: '¡Hola! 📸 Reenvíame tu spam (foto con tu @ y tus enlaces) y te subo a mi historia por {horas}h.',
    },
    pedirFotoPublicado: {
      isEnabled: true,
      text: '¡Hola! Vi que me publicaste 🙌 Para subirte a mi historia necesito tu foto de SFS. '
        + 'Envíamela por aquí y te subo por {horas}h. 📸',
    },
    errorSubir: {
      isEnabled: true,
      text: 'Tuve un problema subiéndote a mi historia. Inténtalo de nuevo.',
    },
  },
  ads: {
    isEnabled: true,
  },
};

const STORE = createStore('sfs-app', 'settings');

const [sfsSettingsSignal, setSfsSettingsSignal] = createSignal<SfsSettings>(DEFAULT_SFS_SETTINGS);

let settingsUserId: string | undefined;

export const getSfsSettings = sfsSettingsSignal;

export async function loadSfsSettings(userId: string) {
  settingsUserId = userId;
  let saved: Partial<SfsSettings> | undefined;
  try {
    saved = await get<Partial<SfsSettings>>(userId, STORE);
  } catch {
    saved = undefined;
  }
  if (settingsUserId !== userId) return;

  setSfsSettingsSignal(mergeWithDefaults(saved));
}

export function updateSfsSettings(update: Partial<SfsSettings>) {
  const newSettings = { ...sfsSettingsSignal(), ...update };
  setSfsSettingsSignal(newSettings);
  void persistSettings(newSettings);
}

export function updateSfsMessage(key: SfsMessageKey, update: Partial<SfsMessageSetting>) {
  const { messages } = sfsSettingsSignal();
  updateSfsSettings({ messages: { ...messages, [key]: { ...messages[key], ...update } } });
}

export function resetSfsMessage(key: SfsMessageKey) {
  updateSfsMessage(key, { text: DEFAULT_SFS_SETTINGS.messages[key].text });
}

// Devuelve el texto listo para mandar, o `undefined` si el mensaje esta apagado o vacio
export function renderSfsMessage(key: SfsMessageKey, settings: SfsSettings) {
  const message = settings.messages[key];
  if (!message.isEnabled) return undefined;

  const template = key === 'gracias' ? pickRandomLine(message.text) : message.text;
  const text = template
    .replaceAll('{horas}', String(settings.durationHours))
    .replaceAll('{minutos}', String(settings.publishTimeoutMin))
    .trim();
  return text || undefined;
}

export function isAdsReady(settings: SfsSettings) {
  return !settings.ads.isEnabled || Boolean(settings.ads.savedMessageId);
}

function pickRandomLine(text: string) {
  const lines = text.split('\n').map((line) => line.trim()).filter(Boolean);
  return lines[Math.floor(Math.random() * lines.length)] || '';
}

async function persistSettings(settings: SfsSettings) {
  if (!settingsUserId) return;
  try {
    await set(settingsUserId, settings, STORE);
  } catch {
    // Si falla el guardado, la configuracion sigue valiendo mientras la app este abierta
  }
}

// Las versiones nuevas pueden traer mensajes que una configuracion vieja no tiene
function mergeWithDefaults(saved?: Partial<SfsSettings>): SfsSettings {
  if (!saved) return DEFAULT_SFS_SETTINGS;

  const messages = { ...DEFAULT_SFS_SETTINGS.messages };
  SFS_MESSAGE_KEYS.forEach((key) => {
    const savedMessage = saved.messages?.[key];
    if (savedMessage) messages[key] = { ...messages[key], ...savedMessage };
  });

  return {
    isEnabled: saved.isEnabled ?? DEFAULT_SFS_SETTINGS.isEnabled,
    durationHours: saved.durationHours ?? DEFAULT_SFS_SETTINGS.durationHours,
    publishTimeoutMin: saved.publishTimeoutMin ?? DEFAULT_SFS_SETTINGS.publishTimeoutMin,
    messages,
    ads: { ...DEFAULT_SFS_SETTINGS.ads, ...saved.ads },
  };
}
