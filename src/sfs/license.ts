import {
  SFS_API_URL,
  SFS_LICENSE_OFFLINE_GRACE,
  SFS_LICENSE_RECHECK_INTERVAL,
  SFS_REQUEST_TIMEOUT,
} from './config';
import { createSignal } from '../util/signals';

export type SfsLicenseState =
  { status: 'loading' }
  | { status: 'valid'; plan: string; validUntil: string; timeRemaining?: string; isOffline?: boolean }
  | { status: 'invalid'; reason: string }
  | { status: 'error'; reason: string };

type StatusResponse = {
  valid: boolean;
  reason?: string;
  plan?: string;
  valid_until?: string;
  time_remaining_str?: string;
};

type RedeemResponse = {
  success?: boolean;
  message?: string;
  detail?: string;
};

type CachedLicense = {
  plan: string;
  validUntil: string;
  checkedAt: number;
};

const CACHE_KEY_PREFIX = 'sfs:license:';

const [sfsLicenseSignal, setSfsLicense] = createSignal<SfsLicenseState>({ status: 'loading' });

let watchedUserId: string | undefined;
let recheckTimer: number | undefined;

export const getSfsLicense = sfsLicenseSignal;

export function isSfsLicenseValid() {
  return sfsLicenseSignal().status === 'valid';
}

export function startSfsLicenseWatcher(userId: string) {
  if (watchedUserId === userId) return;

  stopSfsLicenseWatcher();
  watchedUserId = userId;
  setSfsLicense({ status: 'loading' });
  void checkSfsLicense(userId);
  recheckTimer = window.setInterval(() => {
    void checkSfsLicense(userId);
  }, SFS_LICENSE_RECHECK_INTERVAL);
}

export function stopSfsLicenseWatcher() {
  if (recheckTimer) window.clearInterval(recheckTimer);
  recheckTimer = undefined;
  watchedUserId = undefined;
}

export async function checkSfsLicense(userId: string) {
  let data: StatusResponse;
  try {
    data = await requestJson<StatusResponse>(`/client/status/${encodeURIComponent(userId)}`);
  } catch {
    applyOfflineFallback(userId);
    return;
  }

  if (userId !== watchedUserId) return;

  if (!data.valid || !data.valid_until) {
    removeCachedLicense(userId);
    setSfsLicense({ status: 'invalid', reason: data.reason || 'Sin licencia activa' });
    return;
  }

  const validUntil = normalizeServerDate(data.valid_until);
  const plan = data.plan || '';
  saveCachedLicense(userId, { plan, validUntil, checkedAt: Date.now() });
  setSfsLicense({
    status: 'valid', plan, validUntil, timeRemaining: data.time_remaining_str,
  });
}

export async function redeemSfsLicense({
  key, userId, username, fullName,
}: {
  key: string;
  userId: string;
  username?: string;
  fullName?: string;
}): Promise<{ isOk: boolean; message: string }> {
  let data: RedeemResponse;
  try {
    data = await requestJson<RedeemResponse>('/client/redeem', {
      method: 'POST',
      body: JSON.stringify({
        key: key.trim().toUpperCase(),
        telegram_id: userId,
        telegram_username: username,
        telegram_name: fullName,
      }),
    }, true);
  } catch {
    return { isOk: false, message: 'No pude conectar con el servidor. Revisa tu internet e intenta de nuevo.' };
  }

  if (!data.success) {
    return { isOk: false, message: data.detail || 'No se pudo activar la licencia' };
  }

  await checkSfsLicense(userId);
  return { isOk: true, message: data.message || 'Licencia activada' };
}

export function formatSfsDate(isoDate: string) {
  const date = new Date(isoDate);
  const day = String(date.getDate()).padStart(2, '0');
  const month = String(date.getMonth() + 1).padStart(2, '0');
  return `${day}/${month}/${date.getFullYear()}`;
}

async function requestJson<T>(path: string, init?: RequestInit, shouldReadErrorBody?: boolean): Promise<T> {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), SFS_REQUEST_TIMEOUT);
  try {
    const response = await fetch(`${SFS_API_URL}${path}`, {
      ...init,
      headers: { 'Content-Type': 'application/json' },
      signal: controller.signal,
    });
    if (!response.ok && !shouldReadErrorBody) {
      throw new Error(`HTTP ${response.status}`);
    }
    return await response.json() as T;
  } finally {
    window.clearTimeout(timeout);
  }
}

function applyOfflineFallback(userId: string) {
  if (userId !== watchedUserId) return;

  const cached = getCachedLicense(userId);
  const now = Date.now();
  if (cached && now - cached.checkedAt < SFS_LICENSE_OFFLINE_GRACE && Date.parse(cached.validUntil) > now) {
    setSfsLicense({
      status: 'valid', plan: cached.plan, validUntil: cached.validUntil, isOffline: true,
    });
    return;
  }

  setSfsLicense({ status: 'error', reason: 'No pude conectar con el servidor de licencias' });
}

// El backend guarda las fechas en UTC sin zona horaria
function normalizeServerDate(date: string) {
  const hasZone = /[zZ]|[+-]\d{2}:\d{2}$/.test(date);
  return new Date(hasZone ? date : `${date}Z`).toISOString();
}

function getCachedLicense(userId: string): CachedLicense | undefined {
  try {
    const raw = localStorage.getItem(`${CACHE_KEY_PREFIX}${userId}`);
    return raw ? JSON.parse(raw) as CachedLicense : undefined;
  } catch {
    return undefined;
  }
}

function saveCachedLicense(userId: string, license: CachedLicense) {
  try {
    localStorage.setItem(`${CACHE_KEY_PREFIX}${userId}`, JSON.stringify(license));
  } catch {
    // El almacenamiento puede no estar disponible; la licencia se vuelve a consultar al servidor
  }
}

function removeCachedLicense(userId: string) {
  try {
    localStorage.removeItem(`${CACHE_KEY_PREFIX}${userId}`);
  } catch {
    // Igual que arriba
  }
}
