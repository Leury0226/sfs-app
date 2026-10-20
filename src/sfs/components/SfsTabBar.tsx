// Barra de abajo estilo Telegram para iPhone: Contactos · Chats · Ajustes (solo en pantallas de movil)
import { memo } from '../../lib/teact/teact';
import { getActions, withGlobal } from '../../global';

import type { IconName } from '../../types/icons';
import { LeftColumnContent, SettingsScreens } from '../../types';

import { ALL_FOLDER_ID } from '../../config';
import { selectCurrentChat, selectIsForumPanelOpen, selectTabState } from '../../global/selectors';
import buildClassName from '../../util/buildClassName';

import useAppLayout from '../../hooks/useAppLayout';
import { useFolderManagerForUnreadCounters } from '../../hooks/useFolderManager';

import Icon from '../../components/common/icons/Icon';

import styles from './SfsTabBar.module.scss';

type Tab = 'contacts' | 'chats' | 'settings';

type StateProps = {
  activeTab?: Tab;
  isChatOpen: boolean;
};

const MAX_BADGE = 999;

const TABS: { id: Tab; title: string; icon: IconName; activeIcon: IconName }[] = [
  {
    id: 'contacts', title: 'Contactos', icon: 'user', activeIcon: 'user-filled',
  },
  {
    id: 'chats', title: 'Chats', icon: 'chats-badge', activeIcon: 'chats-badge',
  },
  {
    id: 'settings', title: 'Ajustes', icon: 'settings', activeIcon: 'settings-filled',
  },
];

const SfsTabBar = ({ activeTab, isChatOpen }: StateProps) => {
  const { openLeftColumnContent, openSettingsScreen } = getActions();
  const { isMobile } = useAppLayout();
  const unreadCount = useFolderManagerForUnreadCounters()[ALL_FOLDER_ID]?.notificationsCount || 0;

  if (!isMobile || isChatOpen || !activeTab) return undefined;

  function handleSelect(tab: Tab) {
    if (tab === activeTab) return;

    if (tab === 'contacts') {
      openLeftColumnContent({ contentKey: LeftColumnContent.Contacts });
    } else if (tab === 'settings') {
      openLeftColumnContent({ contentKey: LeftColumnContent.Settings });
      openSettingsScreen({ screen: SettingsScreens.Main });
    } else {
      openLeftColumnContent({ contentKey: LeftColumnContent.ChatList });
    }
  }

  return (
    <nav id="SfsTabBar" className={styles.root}>
      {TABS.map((tab) => {
        const isActive = tab.id === activeTab;
        return (
          <button
            key={tab.id}
            type="button"
            className={buildClassName(styles.tab, isActive && styles.active)}
            onClick={() => handleSelect(tab.id)}
          >
            <span className={styles.iconWrapper}>
              <Icon name={isActive ? tab.activeIcon : tab.icon} className={styles.icon} />
              {tab.id === 'chats' && unreadCount > 0 && (
                <span className={styles.badge}>{unreadCount > MAX_BADGE ? `${MAX_BADGE}+` : unreadCount}</span>
              )}
            </span>
            <span className={styles.title}>{tab.title}</span>
          </button>
        );
      })}
    </nav>
  );
};

export default memo(withGlobal(
  (global): Complete<StateProps> => {
    const { leftColumn } = selectTabState(global);
    const isChatOpen = Boolean(selectCurrentChat(global)) || selectIsForumPanelOpen(global);

    let activeTab: Tab | undefined;
    if (leftColumn.contentKey === LeftColumnContent.ChatList) {
      activeTab = 'chats';
    } else if (leftColumn.contentKey === LeftColumnContent.Contacts) {
      activeTab = 'contacts';
    } else if (leftColumn.contentKey === LeftColumnContent.Settings
      && leftColumn.settingsScreen === SettingsScreens.Main) {
      activeTab = 'settings';
    }

    return { activeTab, isChatOpen };
  },
)(SfsTabBar));
