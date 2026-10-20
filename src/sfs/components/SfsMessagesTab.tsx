import { memo } from '../../lib/teact/teact';

import { SFS_PROMO_TEXT } from '../config';
import {
  DEFAULT_SFS_SETTINGS,
  getSfsSettings,
  resetSfsMessage,
  SFS_MESSAGE_INFO,
  SFS_MESSAGE_KEYS,
  type SfsMessageKey,
  updateSfsMessage,
} from '../settings';

import useDerivedState from '../../hooks/useDerivedState';
import useLastCallback from '../../hooks/useLastCallback';

import Button from '../../components/ui/Button';
import Switcher from '../../components/ui/Switcher';
import TextArea from '../../components/ui/TextArea';

import styles from './SfsPanel.module.scss';

const SfsMessagesTab = () => {
  const settings = useDerivedState(getSfsSettings);

  const handleToggle = useLastCallback((key: SfsMessageKey, isChecked: boolean) => {
    updateSfsMessage(key, { isEnabled: isChecked });
  });

  const handleTextChange = useLastCallback((key: SfsMessageKey, e: React.ChangeEvent<HTMLTextAreaElement>) => {
    updateSfsMessage(key, { text: e.target.value });
  });

  return (
    <>
      <p className={styles.muted}>
        Apaga los mensajes que no quieras mandar y edita el texto como te guste.
        Puedes usar
        {' '}
        {'{horas}'}
        {' '}
        y
        {' '}
        {'{minutos}'}
        .
      </p>
      {SFS_MESSAGE_KEYS.map((key) => {
        const message = settings.messages[key];
        const isDefault = message.text === DEFAULT_SFS_SETTINGS.messages[key].text;

        return (
          <div key={key} className={styles.card}>
            <div className={styles.switchRow}>
              <div>
                <div className={styles.cardTitle}>{SFS_MESSAGE_INFO[key].title}</div>
                <p className={styles.muted}>{SFS_MESSAGE_INFO[key].description}</p>
              </div>
              <Switcher
                label={SFS_MESSAGE_INFO[key].title}
                checked={message.isEnabled}
                onCheck={(isChecked) => handleToggle(key, isChecked)}
              />
            </div>
            {message.isEnabled && (
              <>
                <TextArea
                  value={message.text}
                  label="Texto"
                  noReplaceNewlines
                  onChange={(e) => handleTextChange(key, e)}
                />
                {!isDefault && (
                  <Button size="smaller" color="translucent" onClick={() => resetSfsMessage(key)}>
                    Restaurar texto original
                  </Button>
                )}
              </>
            )}
          </div>
        );
      })}
      <div className={styles.card}>
        <div className={styles.cardTitle}>Anuncio de SFS Story Bot</div>
        <p className={styles.muted}>
          Se manda después del gracias, al completar cada SFS. Este no se puede apagar ni editar.
        </p>
        <div className={styles.adsPreview}>{SFS_PROMO_TEXT}</div>
      </div>
    </>
  );
};

export default memo(SfsMessagesTab);
