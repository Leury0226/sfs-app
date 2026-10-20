import { memo } from '../../lib/teact/teact';

import buildClassName from '../../util/buildClassName';
import { getSfsState, type SfsLogLevel } from '../store';

import useDerivedState from '../../hooks/useDerivedState';

import styles from './SfsPanel.module.scss';

const LEVEL_CLASS_NAMES: Record<SfsLogLevel, string> = {
  info: styles.logInfo,
  success: styles.logSuccess,
  warning: styles.logWarning,
  error: styles.logError,
};

const SfsActivityTab = () => {
  const state = useDerivedState(getSfsState);

  if (!state.log.length) {
    return (
      <p className={styles.muted}>Aquí vas a ver lo que hace el SFS: a quién subió, quién te publicó y errores.</p>
    );
  }

  return (
    <div className={styles.log}>
      {state.log.map((entry) => (
        <div
          key={`${entry.date}-${entry.text}`}
          className={buildClassName(styles.logEntry, LEVEL_CLASS_NAMES[entry.level])}
        >
          <span className={styles.logTime}>{formatTime(entry.date)}</span>
          <span>{entry.text}</span>
        </div>
      ))}
    </div>
  );
};

function formatTime(date: number) {
  const time = new Date(date);
  return `${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}`;
}

export default memo(SfsActivityTab);
