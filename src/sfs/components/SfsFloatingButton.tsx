import {
  memo, useEffect, useRef, useState,
} from '../../lib/teact/teact';

import buildClassName from '../../util/buildClassName';
import { getSfsLicense } from '../license';
import { openSfsPanel } from '../panelState';
import { getSfsSettings } from '../settings';

import useDerivedState from '../../hooks/useDerivedState';
import useLastCallback from '../../hooks/useLastCallback';

import styles from './SfsFloatingButton.module.scss';

type Side = 'left' | 'right';
type Position = { side: Side; top: number };

const STORAGE_KEY = 'sfs:floatingButton';
const BUTTON_SIZE = 56;
const EDGE_MARGIN = 8;
// Movimiento minimo para que cuente como arrastre y no como toque
const DRAG_THRESHOLD = 6;
// Posicion inicial: a la derecha, un poco arriba del centro (no tapa el lapiz ni el campo de mensaje)
const DEFAULT_POSITION: Position = { side: 'right', top: 0.4 };

const SfsFloatingButton = () => {
  const license = useDerivedState(getSfsLicense);
  const settings = useDerivedState(getSfsSettings);

  const [position, setPosition] = useState<Position>(readPosition);
  const [dragPoint, setDragPoint] = useState<{ x: number; y: number } | undefined>();
  const dragStartRef = useRef<{ x: number; y: number; pointerId: number } | undefined>();
  const isDraggingRef = useRef(false);
  const [viewportHeight, setViewportHeight] = useState(window.innerHeight);

  // Al girar o cambiar el tamaño de la ventana, el boton se reacomoda
  useEffect(() => {
    const handleResize = () => setViewportHeight(window.innerHeight);
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  const handlePointerDown = useLastCallback((e: React.PointerEvent<HTMLButtonElement>) => {
    dragStartRef.current = { x: e.clientX, y: e.clientY, pointerId: e.pointerId };
    isDraggingRef.current = false;
    e.currentTarget.setPointerCapture(e.pointerId);
  });

  const handlePointerMove = useLastCallback((e: React.PointerEvent<HTMLButtonElement>) => {
    const start = dragStartRef.current;
    if (!start || start.pointerId !== e.pointerId) return;

    if (!isDraggingRef.current
      && Math.hypot(e.clientX - start.x, e.clientY - start.y) < DRAG_THRESHOLD) return;

    isDraggingRef.current = true;
    setDragPoint({ x: e.clientX, y: e.clientY });
  });

  const handlePointerUp = useLastCallback((e: React.PointerEvent<HTMLButtonElement>) => {
    const start = dragStartRef.current;
    dragStartRef.current = undefined;
    if (!start || start.pointerId !== e.pointerId) return;

    if (!isDraggingRef.current) {
      openSfsPanel();
      return;
    }

    isDraggingRef.current = false;
    setDragPoint(undefined);
    const newPosition: Position = {
      side: e.clientX < window.innerWidth / 2 ? 'left' : 'right',
      top: clamp(e.clientY / window.innerHeight, 0, 1),
    };
    setPosition(newPosition);
    savePosition(newPosition);
  });

  const handlePointerCancel = useLastCallback(() => {
    dragStartRef.current = undefined;
    isDraggingRef.current = false;
    setDragPoint(undefined);
  });

  const status = getStatus(license.status, settings.isEnabled);
  const maxTop = viewportHeight - BUTTON_SIZE - EDGE_MARGIN;
  const style = dragPoint
    ? `left: ${dragPoint.x - BUTTON_SIZE / 2}px; top: ${clamp(dragPoint.y - BUTTON_SIZE / 2, EDGE_MARGIN, maxTop)}px;`
    : `${position.side}: ${EDGE_MARGIN}px; top: ${clamp(position.top * viewportHeight - BUTTON_SIZE / 2,
      EDGE_MARGIN, maxTop)}px;`;

  return (
    <button
      type="button"
      className={buildClassName(styles.root, styles[status], dragPoint && styles.dragging)}
      style={style}
      aria-label="Abrir SFS"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
    >
      <span className={styles.label}>SFS</span>
      <span className={styles.dot} />
    </button>
  );
};

function getStatus(licenseStatus: string, isEnabled: boolean) {
  if (licenseStatus === 'invalid' || licenseStatus === 'error') return 'locked';
  if (licenseStatus === 'valid' && isEnabled) return 'on';
  return 'off';
}

function readPosition(): Position {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || 'null') as Position | null;
    if (saved && (saved.side === 'left' || saved.side === 'right') && typeof saved.top === 'number') return saved;
  } catch {
    // Sin almacenamiento disponible: se usa la posicion inicial
  }
  return DEFAULT_POSITION;
}

function savePosition(position: Position) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(position));
  } catch {
    // Igual que arriba
  }
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

export default memo(SfsFloatingButton);
