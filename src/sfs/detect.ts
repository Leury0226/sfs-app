// Reglas de deteccion portadas de `backend/sfs_flow.py` y `bot/sfs_runner.py` del bot del servidor

// Marca invisible para que las cuentas del sistema (bot y app) se reconozcan entre si
export const SFS_BOT_SIGNATURE = '​‌​‍​';

const MENTION_REGEX = /@[A-Za-z0-9_]{3,}/;
const USERNAME_CAPTURE_REGEX = /@([A-Za-z0-9_]{3,32})/;
const LINK_REGEX = /(t\.me\/|telegram\.me\/|https?:\/\/)/;
const USE_GO_REGEX = /\b(use|go)\b/i;
const SERVICE_WORDS = ['servicio', 'canal', 'grupo', 'promo', 'publicidad', 'historia', 'story'];
const REQUEST_KEYWORDS = ['sfs', 's4s', 'share for share', 'sf?', 'sfs?', 'send for send'];

export function addSfsSignature(text: string) {
  return `${text}${SFS_BOT_SIGNATURE}`;
}

export function hasSfsSignature(text?: string) {
  return Boolean(text?.includes(SFS_BOT_SIGNATURE));
}

// `is_sfs_message`: la palabra "sfs", o un @usuario junto con un link o palabra de servicio
export function isSfsMessage(text?: string) {
  if (!text) return false;

  const lower = text.toLowerCase();
  if (lower.includes('sfs')) return true;

  const hasMention = MENTION_REGEX.test(text);
  const hasLink = LINK_REGEX.test(lower);
  const hasService = SERVICE_WORDS.some((word) => lower.includes(word));
  return hasMention && (hasLink || hasService);
}

// `is_sfs_with_photo`: con foto basta un @usuario o un link
export function isSfsWithPhoto(text: string | undefined, hasPhoto: boolean) {
  if (isSfsMessage(text)) return true;
  if (!hasPhoto) return false;

  return hasPromoData(text);
}

// Texto que trae datos de promo (@usuario o link)
export function hasPromoData(text?: string) {
  if (!text) return false;
  return MENTION_REGEX.test(text) || LINK_REGEX.test(text.toLowerCase());
}

// `is_sfs_request_only`: solo pide SFS, sin promo
export function isSfsRequestOnly(text?: string) {
  if (!text) return false;
  const lower = text.toLowerCase();
  return REQUEST_KEYWORDS.some((keyword) => lower.includes(keyword));
}

// Palabras "use" / "go": la persona da a entender que ya hizo su parte
export function isUseGoKeyword(text?: string) {
  return Boolean(text && USE_GO_REGEX.test(text));
}

// `_foto_parece_promo`: el texto de una foto parece promo
export function isPromoLikeCaption(text?: string) {
  if (!text) return false;
  const lower = text.toLowerCase();
  return text.includes('@') || lower.includes('t.me') || lower.includes('http')
    || lower.includes('channel') || lower.includes('canal') || lower.includes('vip');
}

// `extract_username_from_message`
export function extractUsername(senderUsername: string | undefined, text?: string) {
  if (senderUsername) return senderUsername;
  return text?.match(USERNAME_CAPTURE_REGEX)?.[1];
}
