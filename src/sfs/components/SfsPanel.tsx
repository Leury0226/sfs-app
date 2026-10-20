import {
  memo, useEffect, useState,
} from '../../lib/teact/teact';
import { getActions, withGlobal } from '../../global';

import type { ApiUser } from '../../api/types';

import {
  SFS_APP_VERSION,
  SFS_PRICES,
  SFS_SUPPORT_USERNAME,
  SFS_SUPPORT_WHATSAPP,
} from '../config';
import { selectUser } from '../../global/selectors';
import buildClassName from '../../util/buildClassName';
import { startSfsEngine } from '../engine';
import {
  checkSfsLicense,
  formatSfsDate,
  getSfsLicense,
  redeemSfsLicense,
  startSfsLicenseWatcher,
  stopSfsLicenseWatcher,
} from '../license';
import { closeSfsPanel, getIsSfsPanelOpen } from '../panelState';

import useDerivedState from '../../hooks/useDerivedState';
import useLastCallback from '../../hooks/useLastCallback';

import Button from '../../components/ui/Button';
import InputText from '../../components/ui/InputText';
import Modal from '../../components/ui/Modal';
import Spinner from '../../components/ui/Spinner';
import SfsActivityTab from './SfsActivityTab';
import SfsHomeTab from './SfsHomeTab';
import SfsMessagesTab from './SfsMessagesTab';
import SfsSettingsTab from './SfsSettingsTab';

import styles from './SfsPanel.module.scss';

type SfsTab = 'home' | 'messages' | 'settings' | 'activity';

const TABS: { id: SfsTab; title: string }[] = [
  { id: 'home', title: 'Inicio' },
  { id: 'messages', title: 'Mensajes' },
  { id: 'settings', title: 'Ajustes' },
  { id: 'activity', title: 'Actividad' },
];

type StateProps = {
  currentUserId?: string;
  currentUser?: ApiUser;
};

const SfsPanel = ({ currentUserId, currentUser }: StateProps) => {
  const { openChatByUsername } = getActions();

  const isOpen = useDerivedState(getIsSfsPanelOpen);
  const license = useDerivedState(getSfsLicense);

  const [licenseKey, setLicenseKey] = useState('');
  const [isRedeeming, setIsRedeeming] = useState(false);
  const [redeemError, setRedeemError] = useState<string | undefined>();
  const [redeemSuccess, setRedeemSuccess] = useState<string | undefined>();
  const [activeTab, setActiveTab] = useState<SfsTab>('home');

  // La licencia se consulta al abrir la app, no solo al abrir el panel
  useEffect(() => {
    if (!currentUserId) return undefined;
    startSfsLicenseWatcher(currentUserId);
    void startSfsEngine(currentUserId);
    return stopSfsLicenseWatcher;
  }, [currentUserId]);

  const handleKeyChange = useLastCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    setLicenseKey(e.target.value);
    setRedeemError(undefined);
  });

  const handleRedeem = useLastCallback(async () => {
    if (!currentUserId || !licenseKey.trim()) return;

    setIsRedeeming(true);
    setRedeemError(undefined);
    setRedeemSuccess(undefined);
    const fullName = [currentUser?.firstName, currentUser?.lastName].filter(Boolean).join(' ');
    const result = await redeemSfsLicense({
      key: licenseKey,
      userId: currentUserId,
      username: currentUser?.usernames?.[0]?.username,
      fullName: fullName || undefined,
    });
    setIsRedeeming(false);

    if (result.isOk) {
      setLicenseKey('');
      setRedeemSuccess(result.message);
    } else {
      setRedeemError(result.message);
    }
  });

  const handleKeyDown = useLastCallback((e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter') void handleRedeem();
  });

  const handleRetry = useLastCallback(() => {
    if (currentUserId) void checkSfsLicense(currentUserId);
  });

  const handleContactSupport = useLastCallback(() => {
    closeSfsPanel();
    openChatByUsername({ username: SFS_SUPPORT_USERNAME });
  });

  function renderLoading() {
    return (
      <div className={styles.center}>
        <Spinner color="blue" />
        <p className={styles.muted}>
          {currentUserId ? 'Verificando tu licencia...' : 'Esperando tu cuenta de Telegram...'}
        </p>
      </div>
    );
  }

  function renderValid() {
    if (license.status !== 'valid') return undefined;

    return (
      <>
        <div className={buildClassName(styles.card, styles.cardActive)}>
          <div className={styles.cardTitle}>Licencia activa</div>
          <div className={styles.row}>
            <span className={styles.muted}>Plan</span>
            <span>{license.plan}</span>
          </div>
          <div className={styles.row}>
            <span className={styles.muted}>Vence</span>
            <span>{formatSfsDate(license.validUntil)}</span>
          </div>
          {license.timeRemaining && (
            <div className={styles.row}>
              <span className={styles.muted}>Te queda</span>
              <span>{license.timeRemaining}</span>
            </div>
          )}
          {license.isOffline && (
            <p className={styles.warning}>Sin conexión con el servidor. Usando la última licencia verificada.</p>
          )}
        </div>
        {redeemSuccess && <p className={styles.success}>{redeemSuccess}</p>}
        <div className={styles.tabs}>
          {TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              className={buildClassName(styles.tab, activeTab === tab.id && styles.tabActive)}
              onClick={() => setActiveTab(tab.id)}
            >
              {tab.title}
            </button>
          ))}
        </div>
        {activeTab === 'home' && currentUserId && <SfsHomeTab currentUserId={currentUserId} />}
        {activeTab === 'messages' && <SfsMessagesTab />}
        {activeTab === 'settings' && <SfsSettingsTab />}
        {activeTab === 'activity' && <SfsActivityTab />}
      </>
    );
  }

  function renderRedeem() {
    const reason = license.status === 'invalid' || license.status === 'error' ? license.reason : undefined;

    return (
      <>
        <div className={buildClassName(styles.card, styles.cardLocked)}>
          <div className={styles.cardTitle}>SFS bloqueado</div>
          <p className={styles.muted}>
            {reason}
            . Telegram funciona normal; el módulo SFS necesita una licencia activa.
          </p>
          {license.status === 'error' && (
            <Button size="smaller" color="translucent" onClick={handleRetry}>
              Reintentar
            </Button>
          )}
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>Activar licencia</div>
          <InputText
            value={licenseKey}
            label="Clave de licencia"
            error={redeemError}
            disabled={isRedeeming}
            autoComplete="off"
            onChange={handleKeyChange}
            onKeyDown={handleKeyDown}
          />
          <Button
            isLoading={isRedeeming}
            disabled={!licenseKey.trim() || isRedeeming}
            onClick={handleRedeem}
          >
            Activar
          </Button>
        </div>
        <div className={styles.card}>
          <div className={styles.cardTitle}>¿No tienes licencia?</div>
          {SFS_PRICES.map(({ label, price }) => (
            <div key={label} className={styles.row}>
              <span>{label}</span>
              <span className={styles.price}>{price}</span>
            </div>
          ))}
          <p className={styles.muted}>
            WhatsApp:
            {' '}
            {SFS_SUPPORT_WHATSAPP}
          </p>
          <Button size="smaller" color="translucent" onClick={handleContactSupport}>
            Escribir a @
            {SFS_SUPPORT_USERNAME}
          </Button>
        </div>
      </>
    );
  }

  return (
    <Modal
      isOpen={isOpen}
      title="SFS"
      hasCloseButton
      className={styles.root}
      onClose={closeSfsPanel}
    >
      {license.status === 'loading' && renderLoading()}
      {license.status === 'valid' && renderValid()}
      {(license.status === 'invalid' || license.status === 'error') && renderRedeem()}
      <div className={styles.footer}>
        SFS App v
        {SFS_APP_VERSION}
      </div>
    </Modal>
  );
};

export default memo(withGlobal(
  (global): Complete<StateProps> => {
    const { currentUserId } = global;

    return {
      currentUserId,
      currentUser: currentUserId ? selectUser(global, currentUserId) : undefined,
    };
  },
)(SfsPanel));
