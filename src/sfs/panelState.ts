import { createSignal } from '../util/signals';

const [isSfsPanelOpenSignal, setIsSfsPanelOpen] = createSignal(false);

export const getIsSfsPanelOpen = isSfsPanelOpenSignal;

export function openSfsPanel() {
  setIsSfsPanelOpen(true);
}

export function closeSfsPanel() {
  setIsSfsPanelOpen(false);
}
