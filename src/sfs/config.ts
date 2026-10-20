// Ajustes generales del modulo SFS (codigo propio de SFS App, no viene de Telegram Web A)

export const SFS_APP_VERSION = '0.5.0';

export const SFS_API_URL = 'https://followmytg.com/api';
export const SFS_REQUEST_TIMEOUT = 15000;

// Cada cuanto se vuelve a consultar la licencia con la app abierta
export const SFS_LICENSE_RECHECK_INTERVAL = 60 * 60 * 1000;
// Si el servidor no responde, se acepta la ultima licencia valida guardada durante este tiempo
export const SFS_LICENSE_OFFLINE_GRACE = 12 * 60 * 60 * 1000;

export const SFS_SUPPORT_USERNAME = 'rip0226';
export const SFS_SUPPORT_WHATSAPP = '809 324 5449';

export const SFS_PRICES = [
  { label: '1 Mes', price: 'RD$800' },
  { label: '3 Meses', price: 'RD$2,200' },
  { label: '6 Meses', price: 'RD$4,000' },
  { label: '1 Año', price: 'RD$7,000' },
] as const;

// Perfil seguro del bot del servidor (`security_profiles.py`). Es fijo: protege el API ID de la app
export const SFS_SAFE_DELAY_MIN = 13;
export const SFS_SAFE_DELAY_MAX = 30;

// Copia de `get_promo_message()` del bot del servidor. Se manda al completar cada SFS y no se puede apagar
export const SFS_PROMO_TEXT = [
  '🤖 SFS STORY BOT — automatiza tu SFS',
  '',
  'Deja que tu historia haga SFS sola. Sube, baja y detecta traiciones 24/7. Todo a un clic, sin comandos.',
  '',
  '💳 Licencias desde $300 por una semana',
  '',
  '📢 Mira cómo funciona antes de decidir:',
  '👉 t.me/sfsstoryinfo',
  '',
  'Escríbeme para activarte:',
  '✈️ @rip0226',
  '📱 WhatsApp: 809 324 5449',
].join('\n');
