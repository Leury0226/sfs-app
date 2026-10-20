import { memo, useState } from '../../lib/teact/teact';
import { getActions } from '../../global';

import buildClassName from '../../util/buildClassName';
import { callApi } from '../../api/gramjs';
import { closeSfsPanel } from '../panelState';
import { IS_SFS_IOS_APP } from '../platform';
import { getSfsSettings, isAdsReady, updateSfsSettings } from '../settings';
import { getSfsState, type SfsQueueEntry } from '../store';

import useDerivedState from '../../hooks/useDerivedState';
import useLastCallback from '../../hooks/useLastCallback';

import Button from '../../components/ui/Button';
import Switcher from '../../components/ui/Switcher';

import styles from './SfsPanel.module.scss';

type OwnProps = {
  currentUserId: string;
};

const ADS_PREVIEW_LENGTH = 160;
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;

const SfsHomeTab = ({ currentUserId }: OwnProps) => {
  const { openChat } = getActions();

  const settings = useDerivedState(getSfsSettings);
  const state = useDerivedState(getSfsState);

  const [isLoadingAds, setIsLoadingAds] = useState(false);
  const [adsError, setAdsError] = useState<string | undefined>();

  const [engineError, setEngineError] = useState<string | undefined>();
  // Cambia cuando se rechaza el encendido, para que el interruptor vuelva a verse apagado
  const [switchKey, setSwitchKey] = useState(0);

  const queue = Object.values(state.queue);
  const activeEntries = queue
    .filter((entry) => entry.status === 'active')
    .sort((a, b) => (b.activatedAt || 0) - (a.activatedAt || 0));
  const waitingCount = activeEntries.filter((entry) => !entry.hasTheyPublished).length;

  const handleToggleEngine = useLastCallback((isChecked: boolean) => {
    if (isChecked && !isAdsReady(settings)) {
      setEngineError('Primero configura tu ADS (abajo), o apágalo si no quieres mandarlo.');
      setSwitchKey((key) => key + 1);
      return;
    }
    setEngineError(undefined);
    updateSfsSettings({ isEnabled: isChecked });
  });

  const handleToggleAds = useLastCallback((isChecked: boolean) => {
    updateSfsSettings({ ads: { ...settings.ads, isEnabled: isChecked } });
  });

  const handleUseLastSaved = useLastCallback(async () => {
    setIsLoadingAds(true);
    setAdsError(undefined);
    const { result, error } = await callApi('sfsGetLastSavedMessage');
    setIsLoadingAds(false);

    if (!result) {
      setAdsError(error ? `No pude leer tus Mensajes guardados (${error})` : 'Tus Mensajes guardados están vacíos.');
      return;
    }

    updateSfsSettings({
      ads: {
        ...settings.ads,
        savedMessageId: result.messageId,
        preview: result.text.slice(0, ADS_PREVIEW_LENGTH),
        hasPhoto: result.hasPhoto,
      },
    });
  });

  const handleOpenSaved = useLastCallback(() => {
    closeSfsPanel();
    openChat({ id: currentUserId, shouldReplaceHistory: true });
  });

  return (
    <>
      <div className={buildClassName(styles.card, settings.isEnabled ? styles.cardActive : styles.cardOff)}>
        <div className={styles.switchRow}>
          <div>
            <div className={styles.cardTitle}>{settings.isEnabled ? 'SFS encendido' : 'SFS apagado'}</div>
            <p className={styles.muted}>
              {settings.isEnabled
                ? 'Respondiendo promos y subiendo a tu historia.'
                : 'No empieza SFS nuevos. Los que están en curso se terminan (gracias y bajadas).'}
            </p>
          </div>
          <Switcher key={switchKey} label="Encender SFS" checked={settings.isEnabled} onCheck={handleToggleEngine} />
        </div>
        {engineError && <p className={styles.error}>{engineError}</p>}
        {IS_SFS_IOS_APP && (
          <p className={styles.warning}>
            En iPhone el SFS solo trabaja con la app abierta en pantalla. Mientras esté encendido, la pantalla
            no se apaga sola; déjalo conectado al cargador.
          </p>
        )}
      </div>

      <div className={styles.stats}>
        <div className={styles.stat}>
          <span className={styles.statValue}>{activeEntries.length}</span>
          <span className={styles.muted}>Activos</span>
        </div>
        <div className={styles.stat}>
          <span className={styles.statValue}>{waitingCount}</span>
          <span className={styles.muted}>Esperando</span>
        </div>
        <div className={styles.stat}>
          <span className={styles.statValue}>{state.stats.completedCount}</span>
          <span className={styles.muted}>Completos</span>
        </div>
      </div>

      {Boolean(activeEntries.length) && (
        <div className={styles.card}>
          <div className={styles.cardTitle}>En tu historia</div>
          {activeEntries.map((entry) => (
            <div key={entry.targetId} className={styles.row}>
              <span>{entry.username ? `@${entry.username}` : entry.targetId}</span>
              <span className={entry.hasTheyPublished ? styles.success : styles.muted}>{renderEntryStatus(entry)}</span>
            </div>
          ))}
        </div>
      )}

      <div className={styles.card}>
        <div className={styles.switchRow}>
          <div className={styles.cardTitle}>Tu ADS</div>
          <Switcher label="Mandar ADS" checked={settings.ads.isEnabled} onCheck={handleToggleAds} />
        </div>
        <p className={styles.muted}>
          Mándate tu promo (foto + texto, con emojis premium) a Mensajes guardados y tócale al botón.
          Se manda como copia, igualita.
        </p>
        {settings.ads.savedMessageId ? (
          <div className={styles.adsPreview}>
            <span className={styles.adsBadge}>{settings.ads.hasPhoto ? 'Foto + texto' : 'Solo texto'}</span>
            <span>{settings.ads.preview || '(sin texto)'}</span>
          </div>
        ) : (
          <p className={styles.warning}>Todavía no tienes ADS configurado.</p>
        )}
        {adsError && <p className={styles.error}>{adsError}</p>}
        <div className={styles.buttonRow}>
          <Button size="smaller" isLoading={isLoadingAds} onClick={handleUseLastSaved}>
            Usar mi último guardado
          </Button>
          <Button size="smaller" color="translucent" onClick={handleOpenSaved}>
            Abrir Guardados
          </Button>
        </div>
      </div>
    </>
  );
};

function renderEntryStatus(entry: SfsQueueEntry) {
  const now = Date.now();
  if (entry.hasTheyPublished) {
    return `Completo · quedan ${formatDuration((entry.expiresAt || now) - now)}`;
  }
  if (entry.publishDeadline) {
    return `Esperando · ${formatDuration(entry.publishDeadline - now)} para publicar`;
  }
  return 'Esperando que publique';
}

function formatDuration(ms: number) {
  if (ms <= 0) return '0 min';
  const hours = Math.floor(ms / HOUR);
  const minutes = Math.ceil((ms % HOUR) / MINUTE);
  return hours ? `${hours}h ${minutes}min` : `${minutes} min`;
}

export default memo(SfsHomeTab);
