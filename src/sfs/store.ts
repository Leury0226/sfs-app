import { createStore, get, set } from 'idb-keyval';

import { createSignal } from '../util/signals';

// `active`: lo tengo subido. `awaitingPhoto`: le pedi su foto. `removed`: lo baje por no publicar.
// `closed`: SFS terminado (vencio o se rehizo)
export type SfsQueueStatus = 'active' | 'awaitingPhoto' | 'removed' | 'closed';

// Equivale a una fila de `SFSQueue` del bot del servidor
export type SfsQueueEntry = {
  targetId: string;
  username?: string;
  status: SfsQueueStatus;
  storyId?: number;
  theirStoryId?: number;
  hasTheyPublished?: boolean;
  // Otra cuenta del sistema (bot o app): no se le manda gracias ni pedidos
  isSilent?: boolean;
  activatedAt?: number;
  expiresAt?: number;
  publishDeadline?: number;
  // Ultima vez que se subio a esta persona (anti-bucle)
  lastActionAt?: number;
  // Ultima vez que se le pidio la foto
  askedPhotoAt?: number;
  thanksDueAt?: number;
  isThanksSent?: boolean;
  removedAt?: number;
};

export type SfsLogLevel = 'info' | 'success' | 'warning' | 'error';

export type SfsLogEntry = {
  date: number;
  level: SfsLogLevel;
  text: string;
};

export type SfsState = {
  queue: Record<string, SfsQueueEntry>;
  log: SfsLogEntry[];
  stats: {
    publishedCount: number;
    completedCount: number;
    removedCount: number;
  };
};

const LOG_LIMIT = 100;
const SAVE_DELAY = 1000;

const EMPTY_STATE: SfsState = {
  queue: {},
  log: [],
  stats: { publishedCount: 0, completedCount: 0, removedCount: 0 },
};

const STORE = createStore('sfs-app-state', 'state');

const [sfsStateSignal, setSfsStateSignal] = createSignal<SfsState>(EMPTY_STATE);

let stateUserId: string | undefined;
let saveTimeout: number | undefined;

export const getSfsState = sfsStateSignal;

export async function loadSfsState(userId: string) {
  stateUserId = userId;
  let saved: Partial<SfsState> | undefined;
  try {
    saved = await get<Partial<SfsState>>(userId, STORE);
  } catch {
    saved = undefined;
  }
  if (stateUserId !== userId) return;

  setSfsStateSignal({
    queue: saved?.queue || {},
    log: saved?.log || [],
    stats: { ...EMPTY_STATE.stats, ...saved?.stats },
  });
}

export function getQueueEntry(targetId: string): SfsQueueEntry | undefined {
  return sfsStateSignal().queue[targetId];
}

export function getQueueEntries() {
  return Object.values(sfsStateSignal().queue);
}

export function saveQueueEntry(entry: SfsQueueEntry) {
  const state = sfsStateSignal();
  updateState({ ...state, queue: { ...state.queue, [entry.targetId]: entry } });
}

export function updateQueueEntry(targetId: string, update: Partial<SfsQueueEntry>) {
  const entry = getQueueEntry(targetId);
  if (!entry) return undefined;

  const newEntry = { ...entry, ...update };
  saveQueueEntry(newEntry);
  return newEntry;
}

export function incrementSfsStat(stat: keyof SfsState['stats']) {
  const state = sfsStateSignal();
  updateState({ ...state, stats: { ...state.stats, [stat]: state.stats[stat] + 1 } });
}

export function addSfsLog(level: SfsLogLevel, text: string) {
  const state = sfsStateSignal();
  const log = [{ date: Date.now(), level, text }, ...state.log].slice(0, LOG_LIMIT);
  updateState({ ...state, log });
}

function updateState(state: SfsState) {
  setSfsStateSignal(state);
  scheduleSave();
}

function scheduleSave() {
  if (saveTimeout) return;
  saveTimeout = window.setTimeout(() => {
    saveTimeout = undefined;
    if (!stateUserId) return;
    set(stateUserId, sfsStateSignal(), STORE).catch(() => {
      // Si falla el guardado se reintenta con el proximo cambio
    });
  }, SAVE_DELAY);
}
