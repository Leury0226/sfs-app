import {
  afterEach, beforeEach, describe, expect, it, vi,
} from 'vitest';

// Telegram falso: lo que el motor manda y publica queda registrado aqui
type Sent = { to: string; type: 'text' | 'ads'; text?: string };
const tg = {
  myStories: new Map<number, { userId: string; photoMessageId: number; captionMessageId?: number; suffix?: string }>(),
  partnerStories: new Map<string, { id: number; mentionsMe: boolean }[]>(),
  lastPhotos: new Map<string, number>(),
  sent: [] as Sent[],
  nextStoryId: 1000,
};

const handlers: ((global: unknown, actions: unknown, update: any) => void)[] = [];
const users: Record<string, any> = {};

vi.mock('idb-keyval', () => ({
  createStore: () => ({}),
  get: () => Promise.resolve(undefined),
  set: () => Promise.resolve(),
}));
vi.mock('../../global', () => ({
  addActionHandler: (name: string, handler: any) => {
    if (name === 'apiUpdate') handlers.push(handler);
  },
  getGlobal: () => ({ currentUserId: '100' }),
}));
vi.mock('../../global/selectors', () => ({
  selectTabState: () => ({ isMasterTab: true }),
  selectUser: (global: unknown, id: string) => users[id],
}));
vi.mock('../../util/establishMultitabRole', () => ({ getCurrentTabId: () => 1 }));
vi.mock('../license', () => ({
  isSfsLicenseValid: () => true,
  getSfsLicense: Object.assign(() => ({ status: 'valid' }), { subscribe: () => () => undefined }),
}));
vi.mock('../../api/gramjs', () => ({
  callApi: (name: string, args: any) => Promise.resolve(fakeApi(name, args)),
}));

function fakeApi(name: string, args: any): any {
  switch (name) {
    case 'sfsUserHasMeInStory': {
      const stories = tg.partnerStories.get(args.user.id) || [];
      const story = stories.find((item) => item.mentionsMe);
      return { result: story ? { hasMe: true, storyId: story.id } : { hasMe: false } };
    }
    case 'sfsStoryMentionsMe': {
      const story = (tg.partnerStories.get(args.user.id) || []).find((item) => item.id === args.storyId);
      return { result: Boolean(story?.mentionsMe) };
    }
    case 'sfsHasRecentOwnPhoto':
      return { result: false };
    case 'sfsCountMyStories':
      return { result: tg.myStories.size };
    case 'sfsPublishStoryFromMessage': {
      const id = tg.nextStoryId++;
      tg.myStories.set(id, {
        userId: args.user.id,
        photoMessageId: args.photoMessageId,
        captionMessageId: args.captionMessageId,
        suffix: args.suffixUsername,
      });
      return { result: id };
    }
    case 'sfsSendText':
      tg.sent.push({ to: args.user.id, type: 'text', text: args.text });
      return { result: true };
    case 'sfsSendAdsCopy':
      tg.sent.push({ to: args.user.id, type: 'ads' });
      return { result: true };
    case 'sfsFindLastIncomingPhoto':
      return { result: tg.lastPhotos.get(args.user.id) };
    case 'sfsIsMyStoryActive':
      return { result: tg.myStories.has(args.storyId) };
    case 'sfsDeleteMyStory':
      return { result: tg.myStories.delete(args.storyId) };
    default:
      throw new Error(`API no simulada: ${name}`);
  }
}

const SIGNATURE = '​‌​‍​';
const SECOND = 1000;
const MINUTE = 60 * SECOND;

let engine: typeof import('../engine');
let settings: typeof import('../settings');
let store: typeof import('../store');
let config: typeof import('../config');
let messageId = 1;

function addUser(id: string, username?: string) {
  users[id] = {
    id,
    type: 'userTypeRegular',
    firstName: 'X',
    accessHash: '1',
    usernames: username ? [{ username, isActive: true }] : [],
  };
}

function receive(chatId: string, { text = '', hasPhoto = false, storyData }: {
  text?: string;
  hasPhoto?: boolean;
  storyData?: { id: number; peerId: string; isMention: boolean };
}) {
  const id = messageId++;
  if (hasPhoto) tg.lastPhotos.set(chatId, id);
  const message = {
    id,
    chatId,
    date: Math.floor(Date.now() / 1000),
    isOutgoing: false,
    content: {
      text: text ? { text } : undefined,
      photo: hasPhoto ? {} : undefined,
      storyData: storyData ? { mediaType: 'storyData', ...storyData } : undefined,
    },
  };
  handlers.at(-1)!({}, {}, { '@type': 'newMessage', chatId, id, message });
  return id;
}

function partnerPublishes(userId: string, storyId: number, mentionsMe = true) {
  tg.partnerStories.set(userId, [...(tg.partnerStories.get(userId) || []), { id: storyId, mentionsMe }]);
  handlers.at(-1)!({}, {}, { '@type': 'updateStory', peerId: userId, story: { id: storyId } });
}

const textsTo = (userId: string) => tg.sent.filter((item) => item.to === userId && item.type === 'text')
  .map((item) => item.text!);
const adsTo = (userId: string) => tg.sent.filter((item) => item.to === userId && item.type === 'ads').length;

// Deja correr pausas (delays de 13-30s, cola de publicacion) y el ciclo de cada minuto
const wait = (ms: number) => vi.advanceTimersByTimeAsync(ms);

beforeEach(async () => {
  vi.useFakeTimers({ now: new Date('2026-10-18T12:00:00Z') });
  vi.resetModules();
  handlers.length = 0;
  tg.myStories.clear();
  tg.partnerStories.clear();
  tg.lastPhotos.clear();
  tg.sent = [];
  Object.keys(users).forEach((key) => delete users[key]);
  addUser('100', 'yo_mismo');
  addUser('200', 'ana');

  engine = await import('../engine');
  settings = await import('../settings');
  store = await import('../store');
  config = await import('../config');
  await engine.startSfsEngine('100');
  settings.updateSfsSettings({ isEnabled: true, ads: { isEnabled: true, savedMessageId: 5 } });
});

afterEach(() => {
  vi.useRealTimers();
});

describe('motor SFS', () => {
  it('promo con foto: aviso + ADS, sube a la historia, y al publicarme manda gracias + anuncio', async () => {
    receive('200', { text: 'Sigue a @ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);

    expect(textsTo('200')).toEqual([`✅ Te subí a mi historia por 24h. Súbeme tú también 🙌${SIGNATURE}`]);
    expect(adsTo('200')).toBe(1);
    expect(tg.myStories.size).toBe(1);
    const [story] = [...tg.myStories.values()];
    expect(story).toMatchObject({ userId: '200', suffix: 'ana' });

    const entry = store.getQueueEntry('200')!;
    expect(entry).toMatchObject({ status: 'active', hasTheyPublished: false, username: 'ana' });
    expect(entry.publishDeadline! - entry.activatedAt!).toBe(60 * MINUTE);

    partnerPublishes('200', 77);
    await wait(SECOND);
    expect(store.getQueueEntry('200')).toMatchObject({ hasTheyPublished: true, theirStoryId: 77 });
    expect(textsTo('200')).toHaveLength(1);

    // El gracias sale 1 minuto despues, en el ciclo de cada minuto
    await wait(2 * MINUTE);
    const texts = textsTo('200');
    expect(texts).toHaveLength(3);
    expect(texts[1].endsWith(SIGNATURE)).toBe(true);
    expect(texts[1]).toContain('24h');
    expect(texts[2]).toBe(config.SFS_PROMO_TEXT);

    // SFS completo: silencio total aunque vuelva a escribir
    receive('200', { text: 'sfs?' });
    await wait(MINUTE);
    expect(textsTo('200')).toHaveLength(3);
  });

  it('si no me publica a tiempo, lo baja de mi historia (sin gracias ni anuncio)', async () => {
    receive('200', { text: '@ana_vip promo', hasPhoto: true });
    await wait(31 * SECOND);
    expect(tg.myStories.size).toBe(1);

    await wait(62 * MINUTE);
    expect(tg.myStories.size).toBe(0);
    expect(store.getQueueEntry('200')).toMatchObject({ status: 'removed' });
    expect(store.getSfsState().stats.removedCount).toBe(1);
    expect(textsTo('200')).toHaveLength(1);
  });

  it('pide el spam cuando escriben "sfs" sin foto, y sube la foto que mandan despues', async () => {
    receive('200', { text: 'hacemos sfs?' });
    await wait(31 * SECOND);
    expect(textsTo('200')[0]).toContain('Reenvíame tu spam');
    expect(store.getQueueEntry('200')).toMatchObject({ status: 'awaitingPhoto' });

    // Manda la foto 1 minuto despues: no la bloquea el anti-bucle
    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);
    expect(adsTo('200')).toBe(1);
    expect(tg.myStories.size).toBe(1);
    expect(store.getQueueEntry('200')).toMatchObject({ status: 'active' });
  });

  it('SFS en dos mensajes: foto sola y despues el texto con la promo', async () => {
    const photoId = receive('200', { hasPhoto: true });
    await wait(5 * SECOND);
    expect(tg.myStories.size).toBe(0);

    const textId = receive('200', { text: 'mi canal @ana_vip t.me/anavip' });
    await wait(31 * SECOND);
    const [story] = [...tg.myStories.values()];
    expect(story).toMatchObject({ photoMessageId: photoId, captionMessageId: textId });
  });

  it('respeta los mensajes apagados, pero el anuncio se manda siempre', async () => {
    settings.updateSfsMessage('avisoTiempo', { isEnabled: false });
    settings.updateSfsMessage('gracias', { isEnabled: false });

    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);
    expect(textsTo('200')).toEqual([]);
    expect(adsTo('200')).toBe(1);

    partnerPublishes('200', 77);
    await wait(2 * MINUTE);
    expect(textsTo('200')).toEqual([config.SFS_PROMO_TEXT]);
  });

  it('usa el texto editado del cliente', async () => {
    settings.updateSfsMessage('avisoTiempo', { text: 'Listo, {horas} horas arriba' });
    settings.updateSfsSettings({ durationHours: 12 });

    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);
    expect(textsTo('200')).toEqual([`Listo, 12 horas arriba${SIGNATURE}`]);
  });

  it('con el ADS apagado no manda ADS, pero si sube', async () => {
    settings.updateSfsSettings({ ads: { isEnabled: false } });

    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);
    expect(adsTo('200')).toBe(0);
    expect(tg.myStories.size).toBe(1);
  });

  it('apagado: no empieza nada nuevo, pero termina el SFS en curso', async () => {
    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);
    settings.updateSfsSettings({ isEnabled: false });

    addUser('300', 'beto');
    receive('300', { text: '@beto_vip t.me/beto', hasPhoto: true });
    await wait(31 * SECOND);
    expect(tg.sent.filter((item) => item.to === '300')).toEqual([]);
    expect(tg.myStories.size).toBe(1);

    partnerPublishes('200', 77);
    await wait(2 * MINUTE);
    expect(textsTo('200').at(-1)).toBe(config.SFS_PROMO_TEXT);
  });

  it('otra cuenta del sistema (marca invisible): recibe el ADS, pero no gracias ni anuncio', async () => {
    receive('200', { text: `@ana_vip t.me/anavip${SIGNATURE}`, hasPhoto: true });
    await wait(45 * SECOND);
    expect(adsTo('200')).toBe(1);

    partnerPublishes('200', 77);
    await wait(2 * MINUTE);
    expect(textsTo('200')).toHaveLength(1);
  });

  it('me publica primero y tiene foto en el chat: lo sube y completa sin mandar ADS', async () => {
    tg.lastPhotos.set('200', 42);
    tg.partnerStories.set('200', [{ id: 77, mentionsMe: true }]);
    receive('200', { storyData: { id: 77, peerId: '200', isMention: true } });
    await wait(45 * SECOND);

    expect(adsTo('200')).toBe(0);
    expect([...tg.myStories.values()][0]).toMatchObject({ photoMessageId: 42 });
    expect(store.getQueueEntry('200')).toMatchObject({ status: 'active', hasTheyPublished: true, theirStoryId: 77 });

    await wait(2 * MINUTE);
    expect(textsTo('200').at(-1)).toBe(config.SFS_PROMO_TEXT);
  });

  it('me publica primero sin foto: le pide la foto, y al mandarla queda completo', async () => {
    tg.partnerStories.set('200', [{ id: 77, mentionsMe: true }]);
    receive('200', { storyData: { id: 77, peerId: '200', isMention: true } });
    await wait(5 * SECOND);
    expect(textsTo('200')[0]).toContain('Vi que me publicaste');
    expect(store.getQueueEntry('200')).toMatchObject({ status: 'awaitingPhoto', hasTheyPublished: true });

    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(45 * SECOND);
    expect(adsTo('200')).toBe(0);
    expect(store.getQueueEntry('200')).toMatchObject({ status: 'active', hasTheyPublished: true, theirStoryId: 77 });
  });

  it('una historia que no me menciona no cuenta como publicacion', async () => {
    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);

    partnerPublishes('200', 88, false);
    await wait(SECOND);
    expect(store.getQueueEntry('200')).toMatchObject({ hasTheyPublished: false });
  });

  it('sin ADS configurado no se puede empezar', async () => {
    settings.updateSfsSettings({ ads: { isEnabled: true } });
    expect(engine.canStartNewSfs()).toBe(false);

    receive('200', { text: '@ana_vip t.me/anavip', hasPhoto: true });
    await wait(31 * SECOND);
    expect(tg.sent).toEqual([]);
  });

  it('en iPhone mantiene la pantalla encendida solo con el SFS encendido', () => {
    const calls: unknown[] = [];
    (window as any).webkit = { messageHandlers: { sfsNative: { postMessage: (m: unknown) => calls.push(m) } } };
    settings.updateSfsSettings({ isEnabled: false });
    settings.updateSfsSettings({ isEnabled: true });
    delete (window as any).webkit;

    expect(calls).toEqual([{ keepAwake: false }, { keepAwake: true }]);
  });

  it('mensajes normales no disparan nada', async () => {
    receive('200', { text: 'hola, como estas?' });
    receive('200', { text: 'jaja ok' });
    await wait(MINUTE);
    expect(tg.sent).toEqual([]);
    expect(tg.myStories.size).toBe(0);
  });
});
