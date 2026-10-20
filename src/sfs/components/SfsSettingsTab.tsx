import { memo } from '../../lib/teact/teact';

import { SFS_SAFE_DELAY_MAX, SFS_SAFE_DELAY_MIN } from '../config';
import buildClassName from '../../util/buildClassName';
import {
  getSfsSettings, SFS_DURATION_OPTIONS, SFS_PUBLISH_TIMEOUT_MAX, updateSfsSettings,
} from '../settings';

import useDerivedState from '../../hooks/useDerivedState';
import useLastCallback from '../../hooks/useLastCallback';

import InputText from '../../components/ui/InputText';

import styles from './SfsPanel.module.scss';

const SfsSettingsTab = () => {
  const settings = useDerivedState(getSfsSettings);

  const handlePublishTimeoutChange = useLastCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    updateSfsSettings({ publishTimeoutMin: clampNumber(e.target.value, 0, SFS_PUBLISH_TIMEOUT_MAX) });
  });

  return (
    <>
      <div className={styles.card}>
        <div className={styles.cardTitle}>Duración en tu historia</div>
        <p className={styles.muted}>Cuánto tiempo dura cada SFS.</p>
        <div className={styles.tabs}>
          {SFS_DURATION_OPTIONS.map((hours) => (
            <button
              key={hours}
              type="button"
              className={buildClassName(styles.tab, settings.durationHours === hours && styles.tabActive)}
              onClick={() => updateSfsSettings({ durationHours: hours })}
            >
              {`${hours}h`}
            </button>
          ))}
        </div>
      </div>

      <div className={styles.card}>
        <div className={styles.cardTitle}>Tiempo para que te publiquen</div>
        <p className={styles.muted}>
          Minutos que le das a la otra persona. Si no te publica, la bajo de tu historia. 0 = sin límite.
        </p>
        <InputText
          value={String(settings.publishTimeoutMin)}
          label="Minutos"
          inputMode="numeric"
          onChange={handlePublishTimeoutChange}
        />
      </div>

      <div className={styles.card}>
        <div className={styles.cardTitle}>Perfil seguro (fijo)</div>
        <p className={styles.muted}>
          {`Antes de responder espera entre ${SFS_SAFE_DELAY_MIN} y ${SFS_SAFE_DELAY_MAX} segundos al azar, `}
          y deja 20 a 40 segundos entre historias. Así tu cuenta se comporta como una persona y no como un bot.
        </p>
      </div>
    </>
  );
};

function clampNumber(value: string, min: number, max: number) {
  const number = Number.parseInt(value, 10);
  if (Number.isNaN(number)) return min;
  return Math.min(max, Math.max(min, number));
}

export default memo(SfsSettingsTab);
