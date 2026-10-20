// Llamadas a Telegram del modulo SFS. Corren dentro del worker de GramJS (igual que `src/api/gramjs/methods`).
import { Api as GramJs } from '../../lib/gramjs';
import { RPCError } from '../../lib/gramjs/errors';
import { generateRandomBigInt } from '../../lib/gramjs/Helpers';

import type { ApiUser } from '../../api/types';

import { buildInputPeer, DEFAULT_PRIMITIVES } from '../../api/gramjs/gramjsBuilders';
import {
  getClient, invokeRequest, uploadFile,
} from '../../api/gramjs/methods/client';
import { isPromoLikeCaption } from '../detect';

// Telegram limita el texto de una historia; el bot del servidor usa el mismo tope
const STORY_CAPTION_LIMIT = 2000;
// `GetPeerStories` devuelve solo un lote de las historias mas recientes. Si el lote es grande puede haber
// mas que no vemos: en ese caso no se confirma "no me tiene" (evita acusar en falso)
const UNCERTAIN_BATCH_SIZE = 10;

type SfsResult<T> = { result?: T; error?: string };

type MeInfo = { myId: string; myUsername?: string };

// `publish_story_from_message`: sube la foto como historia conservando texto y formato (emojis premium, links)
export async function sfsPublishStoryFromMessage({
  user, photoMessageId, captionMessageId, periodSeconds, suffixUsername,
}: {
  user: ApiUser;
  photoMessageId: number;
  // Mensaje de texto con la promo cuando la foto vino sin texto (SFS en 2 mensajes)
  captionMessageId?: number;
  periodSeconds: number;
  suffixUsername?: string;
}): Promise<SfsResult<number>> {
  try {
    const ids = captionMessageId ? [photoMessageId, captionMessageId] : [photoMessageId];
    const messages = await fetchRawMessages(user, ids);
    const photoMessage = messages.find((message) => message.id === photoMessageId);
    if (!photoMessage || !(photoMessage.media instanceof GramJs.MessageMediaPhoto)
      || !(photoMessage.media.photo instanceof GramJs.Photo)) {
      return { error: 'NO_PHOTO' };
    }

    const captionMessage = messages.find((message) => message.id === captionMessageId);
    const { caption, entities } = buildStoryCaption(photoMessage, captionMessage, suffixUsername);
    const data = await getClient().downloadMedia(photoMessage.media.photo, {});
    if (!data) return { error: 'DOWNLOAD_FAILED' };

    const file = new File([data as Uint8Array<ArrayBuffer>], 'sfs.jpg', { type: 'image/jpeg' });
    const inputFile = await uploadFile(file);

    const updates = await invokeRequest(new GramJs.stories.SendStory({
      peer: new GramJs.InputPeerSelf(),
      media: new GramJs.InputMediaUploadedPhoto({ file: inputFile }),
      caption,
      entities,
      privacyRules: [new GramJs.InputPrivacyValueAllowAll()],
      randomId: generateRandomBigInt(),
      period: periodSeconds,
    }), { shouldThrow: true });

    const storyId = updates && extractStoryId(updates);
    return storyId ? { result: storyId } : { error: 'NO_STORY_ID' };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

export async function sfsSendText({ user, text }: { user: ApiUser; text: string }): Promise<SfsResult<true>> {
  try {
    await invokeRequest(new GramJs.messages.SendMessage({
      peer: buildInputPeer(user.id, user.accessHash),
      message: text,
      randomId: generateRandomBigInt(),
      noWebpage: true,
    }), { shouldThrow: true });
    return { result: true };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// El ADS se manda como copia (sin "reenviado de") de un mensaje guardado, asi conserva foto y emojis premium
export async function sfsSendAdsCopy({
  user, savedMessageId,
}: {
  user: ApiUser;
  savedMessageId: number;
}): Promise<SfsResult<true>> {
  try {
    await invokeRequest(new GramJs.messages.ForwardMessages({
      fromPeer: new GramJs.InputPeerSelf(),
      id: [savedMessageId],
      randomId: [generateRandomBigInt()],
      toPeer: buildInputPeer(user.id, user.accessHash),
      dropAuthor: true,
    }), { shouldThrow: true });
    return { result: true };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// `find_last_photo_in_chat` (con `shouldPreferPromo`) o la busqueda simple del runner (sin el)
export async function sfsFindLastIncomingPhoto({
  user, limit, maxAgeSeconds, shouldPreferPromo,
}: {
  user: ApiUser;
  limit: number;
  maxAgeSeconds?: number;
  shouldPreferPromo?: boolean;
}): Promise<SfsResult<number>> {
  try {
    const messages = await fetchRawHistory(buildInputPeer(user.id, user.accessHash), limit);
    const minDate = maxAgeSeconds ? Math.floor(Date.now() / 1000) - maxAgeSeconds : 0;
    let fallback: number | undefined;

    for (const message of messages) {
      if (message.out || !(message.media instanceof GramJs.MessageMediaPhoto)) continue;
      if (message.date < minDate) break;
      if (!shouldPreferPromo || isPromoLikeCaption(message.message)) return { result: message.id };
      fallback ??= message.id;
    }

    return { result: fallback };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// `my_ads_sent_recently`: si ya mande una foto mia a este chat hace poco
export async function sfsHasRecentOwnPhoto({
  user, maxAgeSeconds,
}: {
  user: ApiUser;
  maxAgeSeconds: number;
}): Promise<SfsResult<boolean>> {
  const OWN_PHOTO_LOOKUP_LIMIT = 20;
  try {
    const messages = await fetchRawHistory(buildInputPeer(user.id, user.accessHash), OWN_PHOTO_LOOKUP_LIMIT);
    const minDate = Math.floor(Date.now() / 1000) - maxAgeSeconds;
    for (const message of messages) {
      if (!message.out || !(message.media instanceof GramJs.MessageMediaPhoto)) continue;
      return { result: message.date >= minDate };
    }
    return { result: false };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

export async function sfsCountMyStories(): Promise<SfsResult<number>> {
  try {
    const result = await invokeRequest(new GramJs.stories.GetPeerStories({
      peer: new GramJs.InputPeerSelf(),
    }), { shouldThrow: true });
    return { result: result?.stories.stories.length ?? 0 };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// `my_story_still_active`
export async function sfsIsMyStoryActive({ storyId }: { storyId: number }): Promise<SfsResult<boolean>> {
  try {
    const result = await invokeRequest(new GramJs.stories.GetStoriesByID({
      peer: new GramJs.InputPeerSelf(),
      id: [storyId],
    }), { shouldThrow: true });
    const story = result?.stories.find((item) => item.id === storyId);
    return { result: Boolean(story) && !(story instanceof GramJs.StoryItemDeleted) };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// `delete_story`: por ID; si no se puede, busca entre mis historias la que menciona a la persona
export async function sfsDeleteMyStory({
  storyId, username,
}: {
  storyId?: number;
  username?: string;
}): Promise<SfsResult<boolean>> {
  let lastError: string | undefined;
  if (storyId) {
    try {
      const deleted = await invokeRequest(new GramJs.stories.DeleteStories({
        peer: new GramJs.InputPeerSelf(),
        id: [storyId],
      }), { shouldThrow: true });
      if (deleted?.includes(storyId)) return { result: true };
    } catch (err) {
      lastError = getErrorMessage(err);
    }
  }

  if (!username) return { result: false, error: lastError };

  try {
    const result = await invokeRequest(new GramJs.stories.GetPeerStories({
      peer: new GramJs.InputPeerSelf(),
    }), { shouldThrow: true });
    const mention = `@${username.toLowerCase()}`;
    const story = result?.stories.stories.find((item): item is GramJs.StoryItem => (
      item instanceof GramJs.StoryItem && (item.caption || '').toLowerCase().includes(mention)
    ));
    if (!story) return { result: false, error: lastError };

    const deleted = await invokeRequest(new GramJs.stories.DeleteStories({
      peer: new GramJs.InputPeerSelf(),
      id: [story.id],
    }), { shouldThrow: true });
    return { result: Boolean(deleted?.includes(story.id)) };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// `user_has_me_in_story`: `result` true si me tiene, false si seguro que no, sin `result` si no se puede saber
export async function sfsUserHasMeInStory({
  user, myId, myUsername,
}: { user: ApiUser } & MeInfo): Promise<SfsResult<{ hasMe: boolean; storyId?: number }>> {
  try {
    const result = await invokeRequest(new GramJs.stories.GetPeerStories({
      peer: buildInputPeer(user.id, user.accessHash),
    }), { shouldThrow: true });
    const stories = result?.stories.stories.filter((item): item is GramJs.StoryItem => (
      item instanceof GramJs.StoryItem
    )) || [];

    const story = stories.find((item) => doesStoryMentionMe(item, { myId, myUsername }));
    if (story) return { result: { hasMe: true, storyId: story.id } };

    return stories.length >= UNCERTAIN_BATCH_SIZE ? {} : { result: { hasMe: false } };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// Revisa una historia puntual: true si me menciona, false si no (o ya no existe),
// sin `result` si Telegram no deja ver su contenido (por ejemplo, solo para mejores amigos)
export async function sfsStoryMentionsMe({
  user, storyId, myId, myUsername,
}: { user: ApiUser; storyId: number } & MeInfo): Promise<SfsResult<boolean>> {
  try {
    const result = await invokeRequest(new GramJs.stories.GetStoriesByID({
      peer: buildInputPeer(user.id, user.accessHash),
      id: [storyId],
    }), { shouldThrow: true });
    if (!result) return {};

    const story = result.stories.find((item) => item.id === storyId);
    if (!story || story instanceof GramJs.StoryItemDeleted) return { result: false };
    if (!(story instanceof GramJs.StoryItem)) return {};

    return { result: doesStoryMentionMe(story, { myId, myUsername }) };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// Ultimo mensaje de "Mensajes guardados": se usa como ADS
type SavedMessageInfo = { messageId: number; text: string; hasPhoto: boolean };

export async function sfsGetLastSavedMessage(): Promise<SfsResult<SavedMessageInfo>> {
  try {
    const [message] = await fetchRawHistory(new GramJs.InputPeerSelf(), 1);
    if (!message) return {};
    return {
      result: {
        messageId: message.id,
        text: message.message || '',
        hasPhoto: message.media instanceof GramJs.MessageMediaPhoto,
      },
    };
  } catch (err) {
    return { error: getErrorMessage(err) };
  }
}

// Mismas reglas que `user_has_me_in_story`: mi @ en el texto, o una mencion con mi ID o mi @
function doesStoryMentionMe(story: GramJs.StoryItem, { myId, myUsername }: MeInfo) {
  const caption = story.caption || '';
  const mention = myUsername ? `@${myUsername.toLowerCase()}` : undefined;
  if (mention && caption.toLowerCase().includes(mention)) return true;

  return Boolean(story.entities?.some((entity) => {
    if (entity instanceof GramJs.MessageEntityMentionName) return entity.userId.toString() === myId;
    if (entity instanceof GramJs.MessageEntityMention && mention) {
      return caption.slice(entity.offset, entity.offset + entity.length).toLowerCase() === mention;
    }
    return false;
  }));
}

async function fetchRawMessages(user: ApiUser, ids: number[]) {
  const result = await invokeRequest(new GramJs.messages.GetMessages({
    id: ids.map((id) => new GramJs.InputMessageID({ id })),
  }), { shouldThrow: true, shouldIgnoreUpdates: true });
  if (!result || result instanceof GramJs.messages.MessagesNotModified) return [];

  return result.messages.filter((message): message is GramJs.Message => (
    message instanceof GramJs.Message
    && message.peerId instanceof GramJs.PeerUser && message.peerId.userId.toString() === user.id
  ));
}

async function fetchRawHistory(peer: GramJs.TypeInputPeer, limit: number) {
  const result = await invokeRequest(new GramJs.messages.GetHistory({
    peer,
    limit,
    offsetId: DEFAULT_PRIMITIVES.INT,
    offsetDate: DEFAULT_PRIMITIVES.INT,
    addOffset: DEFAULT_PRIMITIVES.INT,
    maxId: DEFAULT_PRIMITIVES.INT,
    minId: DEFAULT_PRIMITIVES.INT,
    hash: DEFAULT_PRIMITIVES.BIGINT,
  }), { shouldThrow: true, shouldIgnoreUpdates: true });
  if (!result || result instanceof GramJs.messages.MessagesNotModified) return [];

  return result.messages.filter((message): message is GramJs.Message => message instanceof GramJs.Message);
}

// Igual que el bot: si la foto trae texto con formato se usa ese; si no, el texto de la promo; y siempre se agrega
// el @ de la persona al final en una linea nueva (respaldo para que la mencion nunca falle)
function buildStoryCaption(photoMessage: GramJs.Message, captionMessage?: GramJs.Message, suffixUsername?: string) {
  const hasFormattedPhotoText = Boolean(photoMessage.message && photoMessage.entities?.length);
  const source = !hasFormattedPhotoText && captionMessage?.message ? captionMessage : photoMessage;
  const sourceText = source.message || '';

  const suffix = suffixUsername ? `@${suffixUsername}` : '';
  const separator = sourceText && suffix ? '\n' : '';
  const maxTextLength = STORY_CAPTION_LIMIT - suffix.length - separator.length;
  const text = sourceText.slice(0, maxTextLength);
  const entities = source.entities?.filter((entity) => entity.offset + entity.length <= text.length);

  return {
    caption: `${text}${separator}${suffix}`,
    entities: entities?.length ? entities : undefined,
  };
}

function extractStoryId(updates: GramJs.TypeUpdates) {
  if (!(updates instanceof GramJs.Updates || updates instanceof GramJs.UpdatesCombined)) return undefined;

  for (const update of updates.updates) {
    if (update instanceof GramJs.UpdateStoryID) return update.id;
    if (update instanceof GramJs.UpdateStory && update.peer instanceof GramJs.PeerUser) return update.story.id;
  }
  return undefined;
}

function getErrorMessage(err: unknown) {
  if (err instanceof RPCError) return err.errorMessage;
  return err instanceof Error ? err.message : String(err);
}
