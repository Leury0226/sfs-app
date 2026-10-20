// Motor SFS. Porta el flujo del bot del servidor:
// `_process_message_local` y los listeners de historias (bot/sfs_runner.py), `handle_incoming_sfs`,
// `handle_mention`, `handle_published_first_no_promo`, `handle_sfs_request_no_photo`, `send_pending_thanks`,
// `check_publish_timers` y `expire_old_sfs` (backend/sfs_flow.py)
import { addActionHandler, getGlobal } from '../global';

import type { ApiMessage, ApiUser } from '../api/types';

import { SFS_PROMO_TEXT, SFS_SAFE_DELAY_MAX, SFS_SAFE_DELAY_MIN } from './config';
import { selectTabState, selectUser } from '../global/selectors';
import { isUserId } from '../util/entities/ids';
import { getCurrentTabId } from '../util/establishMultitabRole';
import { callApi } from '../api/gramjs';
import {
  addSfsSignature,
  extractUsername,
  hasPromoData,
  hasSfsSignature,
  isSfsRequestOnly,
  isSfsWithPhoto,
  isUseGoKeyword,
} from './detect';
import { getSfsLicense, isSfsLicenseValid } from './license';
import { setKeepScreenAwake } from './platform';
import {
  getSfsSettings, isAdsReady, loadSfsSettings, renderSfsMessage, type SfsMessageKey,
} from './settings';
import {
  addSfsLog,
  getQueueEntries,
  getQueueEntry,
  incrementSfsStat,
  loadSfsState,
  saveQueueEntry,
  type SfsQueueEntry,
  updateQueueEntry,
} from './store';

const SERVICE_NOTIFICATIONS_ID = '777000';
const SECOND = 1000;
const MINUTE = 60 * SECOND;
const HOUR = 60 * MINUTE;

// Mensajes mas viejos que esto (por ejemplo al reconectar) no se procesan
const MAX_MESSAGE_AGE = 10 * MINUTE;
// Anti-bucle: no volver a subir a la misma persona antes de este tiempo
const ACTION_COOLDOWN = 3 * MINUTE;
// No repetir mi ADS si ya mande una foto mia a este chat hace poco
const OWN_ADS_RECENT = 30 * MINUTE;
// No volver a pedir la foto a quien ya te publico antes de este tiempo
const ASK_PHOTO_COOLDOWN = 30 * MINUTE;
// Un pedido de foto sin respuesta se olvida despues de este tiempo
const AWAITING_PHOTO_TTL = 24 * HOUR;
// El gracias se manda 1 minuto despues de completar (anti-choque entre cuentas del sistema)
const THANKS_DELAY = MINUTE;
const PROMO_AFTER_THANKS_DELAY = SECOND;
// Si no se puede confirmar que publico, se le da este tiempo extra una sola vez antes de bajarlo
const PUBLISH_CHECK_RETRY_DELAY = 10 * MINUTE;
// Busqueda de fotos en el chat (mismos limites del runner)
const TEXT_PROMO_PHOTO_LOOKUP_LIMIT = 8;
const PHOTO_LOOKUP_LIMIT = 50;
const REQUEST_PHOTO_MAX_AGE = 15 * MINUTE;
const TELEGRAM_STORY_LIMIT = 100;
// Espacio aleatorio entre publicaciones de historias (cola de publicacion del bot)
const PUBLISH_SPACING_MIN = 20 * SECOND;
const PUBLISH_SPACING_MAX = 40 * SECOND;
const STORY_CHECK_CACHE_TIME = 5 * MINUTE;
// Perfil seguro: pausa entre verificaciones de historias
const CHECK_SPACING = 1.5 * SECOND;
const TICK_INTERVAL = MINUTE;
// Otra cuenta del sistema: la de ID menor actua primero para no chocar
const PEER_SYSTEM_FAST_DELAY = [1, 3] as const;
const PEER_SYSTEM_SLOW_DELAY = [8, 14] as const;
const ALLOWED_STORY_HOURS = [6, 12, 24, 48];

type StoryCheck = { hasMe: boolean; storyId?: number } | undefined;

type IncomingSfs = {
  photoMessageId: number;
  captionMessageId?: number;
  text: string;
  isSilent: boolean;
  check: StoryCheck;
};

let engineUserId: string | undefined;
let tickInterval: number | undefined;
let isTickRunning = false;
let isKeepAwakeSubscribed = false;
let hasWarnedStoryLimit = false;
let nextPublishAt = 0;
let publishChain: Promise<unknown> = Promise.resolve();
const lastPhotoByUser = new Map<string, number>();
const userChains = new Map<string, Promise<void>>();
const knownSystemAccounts = new Set<string>();
const storyCheckCache = new Map<string, { result: StoryCheck; checkedAt: number }>();
const publishCheckRetried = new Set<string>();

addActionHandler('apiUpdate', (global, actions, update): undefined => {
  if (update['@type'] === 'newMessage') {
    handleNewMessage(update.message);
  } else if (update['@type'] === 'updateStory') {
    handleStoryUpdate(update.peerId, update.story.id);
  }
  return undefined;
});

export async function startSfsEngine(userId: string) {
  if (engineUserId === userId) return;

  engineUserId = userId;
  hasWarnedStoryLimit = false;
  lastPhotoByUser.clear();
  userChains.clear();
  storyCheckCache.clear();
  publishCheckRetried.clear();
  await Promise.all([loadSfsSettings(userId), loadSfsState(userId)]);

  syncKeepScreenAwake();
  if (!isKeepAwakeSubscribed) {
    isKeepAwakeSubscribed = true;
    getSfsSettings.subscribe(syncKeepScreenAwake);
    getSfsLicense.subscribe(syncKeepScreenAwake);
  }

  if (tickInterval) window.clearInterval(tickInterval);
  tickInterval = window.setInterval(() => {
    void runTick();
  }, TICK_INTERVAL);
}

function syncKeepScreenAwake() {
  setKeepScreenAwake(getSfsSettings().isEnabled && isSfsLicenseValid());
}

// El motor vigila (gracias, timers, vencimientos) mientras haya licencia
function canRun() {
  if (!engineUserId || !isSfsLicenseValid()) return false;

  const global = getGlobal();
  return global.currentUserId === engineUserId && Boolean(selectTabState(global, getCurrentTabId()).isMasterTab);
}

// SFS nuevos solo con el SFS encendido y el ADS listo. Apagado = no empieza nada nuevo,
// pero termina los que estan en curso (igual que "pausado" en el bot)
export function canStartNewSfs() {
  const settings = getSfsSettings();
  return canRun() && settings.isEnabled && isAdsReady(settings);
}

function handleNewMessage(message: ApiMessage) {
  if (!engineUserId || message.isOutgoing || message.isScheduled) return;

  const { chatId } = message;
  if (chatId === engineUserId || chatId === SERVICE_NOTIFICATIONS_ID || !isUserId(chatId)) return;
  if (message.date * SECOND < Date.now() - MAX_MESSAGE_AGE) return;

  const user = selectUser(getGlobal(), chatId);
  if (!user || user.type === 'userTypeBot' || user.isSelf) return;

  if (message.content.photo) {
    lastPhotoByUser.set(chatId, message.id);
  }

  if (!canRun()) return;

  // "Te menciono en su historia": Telegram avisa con un mensaje
  const { storyData } = message.content;
  if (storyData?.isMention && storyData.peerId === chatId) {
    runForUser(chatId, () => handleStoryMention(user, storyData.id));
    return;
  }

  if (!canStartNewSfs()) return;
  runForUser(chatId, () => processMessage(user, message));
}

// Alguien que tengo en SFS subio una historia: si me menciona, me publico
function handleStoryUpdate(peerId: string, storyId: number) {
  if (!engineUserId || peerId === engineUserId || !isUserId(peerId) || !canRun()) return;

  const entry = getQueueEntry(peerId);
  if (!entry || entry.status === 'closed') return;
  if (entry.status === 'active' && entry.hasTheyPublished && entry.theirStoryId) return;

  const user = selectUser(getGlobal(), peerId);
  if (!user) return;

  runForUser(peerId, async () => {
    const { result: doesMention } = await callApi('sfsStoryMentionsMe', { user, storyId, ...getMeInfo() });
    if (doesMention !== true) return;

    storyCheckCache.set(peerId, { result: { hasMe: true, storyId }, checkedAt: Date.now() });
    await handleTheyPublished(user, storyId);
  });
}

async function handleStoryMention(user: ApiUser, storyId: number) {
  // El aviso de Telegram ya es prueba; solo se descarta si la historia ya no existe o no me menciona
  const { result: doesMention } = await callApi('sfsStoryMentionsMe', { user, storyId, ...getMeInfo() });
  if (doesMention === false) return;

  storyCheckCache.set(user.id, { result: { hasMe: true, storyId }, checkedAt: Date.now() });
  await handleTheyPublished(user, storyId);
}

// `_process_message_local`
async function processMessage(user: ApiUser, message: ApiMessage) {
  if (!canStartNewSfs()) return;

  const text = message.content.text?.text || '';
  const isPeerSystemAccount = hasSfsSignature(text);
  if (isPeerSystemAccount) {
    knownSystemAccounts.add(user.id);
    await pause(getPeerSystemDelay(user.id));
  }
  const isSilent = isPeerSystemAccount || knownSystemAccounts.has(user.id);

  // SFS completo y vigente: silencio total
  if (isSfsComplete(user.id)) return;

  const check = await checkUserHasMe(user);
  if (check?.hasMe) {
    await handleTheyPublished(user, check.storyId);
    return;
  }

  // Caso 1: foto. Solo es promo si trae @ o link; si no, se guarda y se espera el texto
  if (message.content.photo) {
    if (isSfsWithPhoto(text, true)) {
      lastPhotoByUser.delete(user.id);
      await handleIncomingSfs(user, {
        photoMessageId: message.id, text, isSilent, check,
      });
    }
    return;
  }

  // Caso 2: texto con @ o link: se sube con la foto que mando antes
  if (hasPromoData(text)) {
    const photoMessageId = lastPhotoByUser.get(user.id)
      ?? await findLastPhoto(user, { limit: TEXT_PROMO_PHOTO_LOOKUP_LIMIT });
    if (!photoMessageId) {
      addSfsLog('info', `${formatUser(user)} mandó su promo sin foto. Esperando la foto.`);
      return;
    }

    lastPhotoByUser.delete(user.id);
    await handleIncomingSfs(user, {
      photoMessageId, captionMessageId: message.id, text, isSilent, check,
    });
    return;
  }

  // Caso 3: "use" / "go": la persona da a entender que ya hizo su parte; se usa su ultima foto
  if (isUseGoKeyword(text)) {
    const photoMessageId = lastPhotoByUser.get(user.id)
      ?? await findLastPhoto(user, { limit: PHOTO_LOOKUP_LIMIT, shouldPreferPromo: true });
    if (photoMessageId) {
      lastPhotoByUser.delete(user.id);
      await handleIncomingSfs(user, {
        photoMessageId, text, isSilent, check,
      });
    }
    return;
  }

  // Caso 4: solo pide SFS ("sfs", "s4s"...). A otra cuenta del sistema no se le responde
  if (isSilent || !isSfsRequestOnly(text)) return;

  const photoMessageId = lastPhotoByUser.get(user.id) ?? await findLastPhoto(user, {
    limit: PHOTO_LOOKUP_LIMIT, maxAge: REQUEST_PHOTO_MAX_AGE, shouldPreferPromo: true,
  });
  if (photoMessageId) {
    lastPhotoByUser.delete(user.id);
    await handleIncomingSfs(user, {
      photoMessageId, text, isSilent, check,
    });
    return;
  }

  await handleRequestWithoutPhoto(user, check);
}

// `handle_incoming_sfs`: mandar ADS, subir a la historia y esperar que publique
async function handleIncomingSfs(user: ApiUser, {
  photoMessageId, captionMessageId, text, isSilent, check,
}: IncomingSfs) {
  const settings = getSfsSettings();
  const senderUsername = getUsername(user);
  const username = extractUsername(senderUsername, text);
  if (!username || isSfsComplete(user.id)) return;

  let entry = getQueueEntry(user.id);
  if (entry?.lastActionAt && Date.now() - entry.lastActionAt < ACTION_COOLDOWN) return;

  let isAlreadyPublished = check?.hasMe === true;
  let theirStoryId = check?.storyId;

  // Le habia pedido la foto: si ya me habia publicado, al subirlo el SFS queda completo
  if (entry?.status === 'awaitingPhoto') {
    isAlreadyPublished ||= Boolean(entry.hasTheyPublished);
    theirStoryId ??= entry.theirStoryId;
    entry = updateQueueEntry(user.id, { status: 'closed' });
  }

  // Si lo tenia subido pero borre la historia a mano, se rehace el SFS
  if (entry?.status === 'active' && entry.storyId) {
    const { result: isStoryActive } = await callApi('sfsIsMyStoryActive', { storyId: entry.storyId });
    if (isStoryActive === false) {
      entry = updateQueueEntry(user.id, { status: 'closed' });
      addSfsLog('info', `@${username}: tu historia ya no estaba, rehaciendo el SFS.`);
    }
  }

  // Ya esta subido y no me ha publicado: se espera en silencio (sin recordatorios que alimenten bucles)
  if (entry?.status === 'active') {
    const freshCheck = await checkUserHasMe(user, true);
    if (freshCheck?.hasMe) markCompleted(user, freshCheck.storyId);
    return;
  }

  if (!isAlreadyPublished) {
    const freshCheck = await checkUserHasMe(user, true);
    if (freshCheck?.hasMe) {
      isAlreadyPublished = true;
      theirStoryId ??= freshCheck.storyId;
    }
  }

  if (await isStoryLimitReached()) return;
  if (!canStartNewSfs()) return;

  // Mi ADS va antes de subirlo, salvo que ya me haya publicado o que ya le haya mandado mi foto hace poco
  if (!isAlreadyPublished) {
    const { result: hasRecentAds } = await callApi('sfsHasRecentOwnPhoto', {
      user, maxAgeSeconds: OWN_ADS_RECENT / SECOND,
    });
    if (!hasRecentAds) {
      await pause(getSafeDelay());
      if (!canStartNewSfs()) return;
      await sendAds(user, username);
    }
  }

  const { result: storyId, error } = await publishStory(user, {
    photoMessageId, captionMessageId, suffixUsername: senderUsername,
  });
  if (!storyId) {
    addSfsLog('error', `No pude subir a @${username} a tu historia (${formatError(error)}).`);
    await sendConfiguredMessage(user, 'errorSubir');
    return;
  }

  const now = Date.now();
  const timeoutMin = settings.publishTimeoutMin;
  saveQueueEntry({
    targetId: user.id,
    username,
    status: 'active',
    storyId,
    theirStoryId,
    hasTheyPublished: false,
    isSilent,
    activatedAt: now,
    expiresAt: now + settings.durationHours * HOUR,
    publishDeadline: timeoutMin > 0 ? now + timeoutMin * MINUTE : undefined,
    lastActionAt: now,
  });
  publishCheckRetried.delete(user.id);
  incrementSfsStat('publishedCount');

  // Re-verificacion final (carrera entre cuentas): quizas me publico mientras lo subia
  if (!isAlreadyPublished) {
    const finalCheck = await checkUserHasMe(user, true);
    if (finalCheck?.hasMe) {
      isAlreadyPublished = true;
      theirStoryId ??= finalCheck.storyId;
    }
  }

  if (isAlreadyPublished) {
    markCompleted(user, theirStoryId);
    return;
  }

  const waitingText = timeoutMin > 0
    ? `Esperando que te publique (${timeoutMin} min).`
    : 'Sin límite de tiempo para que te publique.';
  addSfsLog('info', `Nuevo SFS: subí a @${username} por ${settings.durationHours}h. ${waitingText}`);
}

// `handle_mention`: la persona ya me tiene en su historia
async function handleTheyPublished(user: ApiUser, theirStoryId?: number) {
  const entry = getQueueEntry(user.id);
  if (entry?.status === 'active') {
    if (!entry.hasTheyPublished) {
      markCompleted(user, theirStoryId);
    } else if (theirStoryId && !entry.theirStoryId) {
      updateQueueEntry(user.id, { theirStoryId });
    }
    return;
  }

  if (!canStartNewSfs()) {
    // Apagado: no se sube a nadie nuevo, pero se recuerda que ya me publico
    if (entry?.status === 'awaitingPhoto' && !entry.hasTheyPublished) {
      updateQueueEntry(user.id, { hasTheyPublished: true, theirStoryId });
    }
    return;
  }

  await handlePublishedFirst(user, theirStoryId);
}

// `handle_published_first_no_promo`: me publico primero; se sube con su ultima foto o se le pide
async function handlePublishedFirst(user: ApiUser, theirStoryId?: number) {
  const settings = getSfsSettings();
  const username = getUsername(user);
  if (!username) return;

  const entry = getQueueEntry(user.id);
  if (entry?.lastActionAt && Date.now() - entry.lastActionAt < ACTION_COOLDOWN) return;

  const photoMessageId = lastPhotoByUser.get(user.id)
    ?? await findLastPhoto(user, { limit: PHOTO_LOOKUP_LIMIT, shouldPreferPromo: true });

  if (!photoMessageId) {
    const hasAskedRecently = entry?.status === 'awaitingPhoto' && entry.askedPhotoAt
      && Date.now() - entry.askedPhotoAt < ASK_PHOTO_COOLDOWN;
    if (hasAskedRecently) {
      if (!entry.hasTheyPublished) updateQueueEntry(user.id, { hasTheyPublished: true, theirStoryId });
      return;
    }

    await sendConfiguredMessage(user, 'pedirFotoPublicado');
    saveQueueEntry({
      targetId: user.id,
      username,
      status: 'awaitingPhoto',
      hasTheyPublished: true,
      theirStoryId,
      isSilent: entry?.isSilent,
      askedPhotoAt: Date.now(),
    });
    addSfsLog('info', `@${username} te publicó pero no tiene foto en el chat. Le pedí que la envíe.`);
    return;
  }

  if (await isStoryLimitReached()) return;
  if (!canStartNewSfs()) return;

  lastPhotoByUser.delete(user.id);
  const { result: storyId, error } = await publishStory(user, { photoMessageId, suffixUsername: username });
  if (!storyId) {
    addSfsLog('error', `@${username} te publicó primero, pero no pude subirlo (${formatError(error)}).`);
    return;
  }

  const now = Date.now();
  saveQueueEntry({
    targetId: user.id,
    username,
    status: 'active',
    storyId,
    theirStoryId,
    hasTheyPublished: false,
    isSilent: entry?.isSilent,
    activatedAt: now,
    expiresAt: now + settings.durationHours * HOUR,
    lastActionAt: now,
  });
  incrementSfsStat('publishedCount');
  addSfsLog('info', `@${username} te publicó primero. Lo subí con su última foto del chat.`);
  markCompleted(user, theirStoryId);
}

// `handle_sfs_request_no_photo`: pide su spam; mi ADS se manda cuando mande su foto
async function handleRequestWithoutPhoto(user: ApiUser, check: StoryCheck) {
  const entry = getQueueEntry(user.id);
  if (entry?.status === 'active' && entry.hasTheyPublished) return;
  if (entry?.status === 'awaitingPhoto' && entry.askedPhotoAt
    && Date.now() - entry.askedPhotoAt < ASK_PHOTO_COOLDOWN) return;
  if (check?.hasMe) return;

  await pause(getSafeDelay());
  if (!canStartNewSfs()) return;

  await sendConfiguredMessage(user, 'pedirSpam');
  saveQueueEntry({
    targetId: user.id,
    username: getUsername(user),
    status: 'awaitingPhoto',
    askedPhotoAt: Date.now(),
  });
  addSfsLog('info', `${formatUser(user)} pidió SFS sin foto. Le pedí su spam.`);
}

function markCompleted(user: ApiUser, theirStoryId?: number) {
  const entry = getQueueEntry(user.id);
  if (!entry || entry.status !== 'active' || entry.hasTheyPublished) return;

  updateQueueEntry(user.id, {
    hasTheyPublished: true,
    publishDeadline: undefined,
    theirStoryId: theirStoryId ?? entry.theirStoryId,
    // A otra cuenta del sistema no se le manda gracias (evita ruido entre bots)
    thanksDueAt: entry.isSilent ? undefined : Date.now() + THANKS_DELAY,
  });
  publishCheckRetried.delete(user.id);
  incrementSfsStat('completedCount');
  addSfsLog('success', `SFS completo con ${formatUser(user)} (${getSfsSettings().durationHours}h). Ambos publicados.`);
}

// Tareas de cada minuto, como el `_periodic_loop` del runner
async function runTick() {
  if (isTickRunning || !canRun()) return;

  isTickRunning = true;
  try {
    expireOldEntries();
    await sendPendingThanks();
    await checkPublishTimers();
  } finally {
    isTickRunning = false;
  }
}

// `expire_old_sfs`: al vencer, el SFS termina y se puede volver a hacer con esa persona
function expireOldEntries() {
  const now = Date.now();
  getQueueEntries().forEach((entry) => {
    const isExpired = entry.status === 'active' && entry.expiresAt && entry.expiresAt <= now;
    const isStaleRequest = entry.status === 'awaitingPhoto'
      && (entry.askedPhotoAt || 0) + AWAITING_PHOTO_TTL <= now;
    const isOldRemoval = entry.status === 'removed' && (entry.removedAt || 0) + AWAITING_PHOTO_TTL <= now;
    if (isExpired || isStaleRequest || isOldRemoval) {
      updateQueueEntry(entry.targetId, { status: 'closed' });
    }
  });
}

// `send_pending_thanks`: gracias (si esta encendido) y despues el anuncio, que siempre se manda
async function sendPendingThanks() {
  const now = Date.now();
  const pending = getQueueEntries().filter((entry) => (
    entry.status === 'active' && entry.thanksDueAt && entry.thanksDueAt <= now && !entry.isThanksSent
  ));

  for (const entry of pending) {
    const user = selectUser(getGlobal(), entry.targetId);
    if (!user) continue;

    // Se marca antes de mandar para no repetir si algo falla
    updateQueueEntry(entry.targetId, { isThanksSent: true, thanksDueAt: undefined });
    await runForUser(entry.targetId, async () => {
      const hasThanks = await sendConfiguredMessage(user, 'gracias');
      if (hasThanks) await pause(PROMO_AFTER_THANKS_DELAY);

      const { error } = await callApi('sfsSendText', { user, text: SFS_PROMO_TEXT });
      if (error) addSfsLog('error', `No pude mandar el anuncio a ${formatUser(user)} (${formatError(error)}).`);
    });
  }
}

// `check_publish_timers`: baja de mi historia a quien no me publico a tiempo
async function checkPublishTimers() {
  if (getSfsSettings().publishTimeoutMin <= 0) return;

  const now = Date.now();
  const overdue = getQueueEntries().filter((entry) => (
    entry.status === 'active' && !entry.hasTheyPublished && entry.publishDeadline && entry.publishDeadline <= now
  ));

  for (const entry of overdue) {
    const user = selectUser(getGlobal(), entry.targetId);
    if (!user) continue;

    await runForUser(entry.targetId, () => removeIfNotPublished(user, entry));
    await pause(CHECK_SPACING);
  }
}

async function removeIfNotPublished(user: ApiUser, entry: SfsQueueEntry) {
  const current = getQueueEntry(user.id);
  if (current?.status !== 'active' || current.hasTheyPublished) return;

  // Antes de bajarlo, verificar en vivo si ya me publico
  const check = await checkUserHasMe(user, true);
  if (check?.hasMe) {
    markCompleted(user, check.storyId);
    return;
  }

  // No se pudo confirmar (tiene muchas historias): una sola oportunidad extra antes de bajarlo
  if (!check && !publishCheckRetried.has(user.id)) {
    publishCheckRetried.add(user.id);
    updateQueueEntry(user.id, { publishDeadline: Date.now() + PUBLISH_CHECK_RETRY_DELAY });
    return;
  }

  const { result: isDeleted } = await callApi('sfsDeleteMyStory', {
    storyId: entry.storyId, username: entry.username,
  });
  updateQueueEntry(user.id, { status: 'removed', removedAt: Date.now(), publishDeadline: undefined });
  publishCheckRetried.delete(user.id);
  incrementSfsStat('removedCount');

  const timeoutMin = getSfsSettings().publishTimeoutMin;
  addSfsLog('warning', isDeleted
    ? `${formatUser(user)} no te publicó en ${timeoutMin} min. Lo bajé de tu historia.`
    : `${formatUser(user)} no te publicó en ${timeoutMin} min. Intenté bajarlo pero la historia ya no estaba.`);
}

function isSfsComplete(userId: string) {
  const entry = getQueueEntry(userId);
  return Boolean(entry && entry.status === 'active' && entry.hasTheyPublished
    && (!entry.expiresAt || entry.expiresAt > Date.now()));
}

// `send_ads`: primero el aviso de tiempo, despues el ADS
async function sendAds(user: ApiUser, username: string) {
  const settings = getSfsSettings();
  const hasNotice = await sendConfiguredMessage(user, 'avisoTiempo');
  if (!settings.ads.isEnabled || !settings.ads.savedMessageId) return;

  if (hasNotice) await pause(SECOND);
  const { error } = await callApi('sfsSendAdsCopy', { user, savedMessageId: settings.ads.savedMessageId });
  if (error) {
    addSfsLog('error', `No pude mandar tu ADS a @${username} (${formatError(error)}). Revisa que siga en `
    + 'tus Mensajes guardados.');
  }
}

// Devuelve true si el mensaje se mando. Llevan la marca invisible, igual que en el bot
async function sendConfiguredMessage(user: ApiUser, key: SfsMessageKey) {
  const text = renderSfsMessage(key, getSfsSettings());
  if (!text) return false;

  const { error } = await callApi('sfsSendText', { user, text: addSfsSignature(text) });
  if (error) {
    addSfsLog('error', `No pude mandar un mensaje a ${formatUser(user)} (${formatError(error)}).`);
    return false;
  }
  return true;
}

// Cola de publicacion: una historia a la vez, con 20-40s aleatorios entre una y otra
function publishStory(user: ApiUser, {
  photoMessageId, captionMessageId, suffixUsername,
}: {
  photoMessageId: number;
  captionMessageId?: number;
  suffixUsername?: string;
}) {
  const { durationHours } = getSfsSettings();
  const periodHours = ALLOWED_STORY_HOURS.reduce((best, hours) => (
    Math.abs(hours - durationHours) < Math.abs(best - durationHours) ? hours : best
  ));

  const run = async () => {
    const wait = nextPublishAt - Date.now();
    if (wait > 0) await pause(wait);
    nextPublishAt = Date.now() + randomBetween(PUBLISH_SPACING_MIN, PUBLISH_SPACING_MAX);

    return callApi('sfsPublishStoryFromMessage', {
      user,
      photoMessageId,
      captionMessageId,
      periodSeconds: periodHours * HOUR / SECOND,
      suffixUsername,
    });
  };

  const result = publishChain.then(run);
  publishChain = result.catch(() => undefined);
  return result;
}

async function isStoryLimitReached() {
  const { result: count } = await callApi('sfsCountMyStories');
  if (count === undefined || count < TELEGRAM_STORY_LIMIT) {
    hasWarnedStoryLimit = false;
    return false;
  }

  if (!hasWarnedStoryLimit) {
    hasWarnedStoryLimit = true;
    addSfsLog('warning', `Historia llena (${count}/${TELEGRAM_STORY_LIMIT}). No se suben más SFS hasta que se `
    + 'libere espacio (cuando expiren o bajes historias).');
  }
  return true;
}

async function checkUserHasMe(user: ApiUser, shouldSkipCache?: boolean): Promise<StoryCheck> {
  const cached = storyCheckCache.get(user.id);
  if (!shouldSkipCache && cached && Date.now() - cached.checkedAt < STORY_CHECK_CACHE_TIME) {
    return cached.result;
  }

  const { result } = await callApi('sfsUserHasMeInStory', { user, ...getMeInfo() });
  if (result) {
    storyCheckCache.set(user.id, { result, checkedAt: Date.now() });
  }
  return result;
}

async function findLastPhoto(user: ApiUser, { limit, maxAge, shouldPreferPromo }: {
  limit: number;
  maxAge?: number;
  shouldPreferPromo?: boolean;
}) {
  const { result } = await callApi('sfsFindLastIncomingPhoto', {
    user, limit, maxAgeSeconds: maxAge ? maxAge / SECOND : undefined, shouldPreferPromo,
  });
  return result;
}

// Un paso a la vez por persona, como el lock por usuario del runner
function runForUser(userId: string, task: () => Promise<void>) {
  const previous = userChains.get(userId) || Promise.resolve();
  const next = previous
    .then(task)
    .catch((err) => {
      addSfsLog('error', `Error con ${userId}: ${String(err)}`);
    });
  userChains.set(userId, next);
  return next;
}

function getMeInfo() {
  const me = selectUser(getGlobal(), engineUserId!);
  return { myId: engineUserId!, myUsername: me && getUsername(me) };
}

function getUsername(user: ApiUser) {
  return user.usernames?.find((item) => item.isActive)?.username;
}

function formatUser(user: ApiUser) {
  const username = getUsername(user);
  return username ? `@${username}` : (user.firstName || user.id);
}

function formatError(error?: string) {
  if (error === 'STORIES_TOO_MUCH') return 'llegaste al límite de historias';
  if (error === 'NO_PHOTO') return 'no encontré la foto';
  return error || 'error desconocido';
}

function getSafeDelay() {
  return randomBetween(SFS_SAFE_DELAY_MIN * SECOND, SFS_SAFE_DELAY_MAX * SECOND);
}

function getPeerSystemDelay(peerId: string) {
  const [min, max] = BigInt(engineUserId!) < BigInt(peerId) ? PEER_SYSTEM_FAST_DELAY : PEER_SYSTEM_SLOW_DELAY;
  return randomBetween(min * SECOND, max * SECOND);
}

function randomBetween(min: number, max: number) {
  return min + Math.random() * (max - min);
}

function pause(ms: number) {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}
