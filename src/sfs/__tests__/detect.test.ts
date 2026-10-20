import { describe, expect, it } from 'vitest';

import {
  addSfsSignature, extractUsername, hasPromoData, hasSfsSignature, isSfsMessage, isSfsRequestOnly, isSfsWithPhoto,
  isUseGoKeyword,
} from '../detect';

describe('detect', () => {
  it('detecta promos igual que el bot', () => {
    expect(isSfsMessage('hacemos SFS?')).toBe(true);
    expect(isSfsMessage('@canal_vip t.me/canalvip')).toBe(true);
    expect(isSfsMessage('@canal_vip mi canal')).toBe(true);
    expect(isSfsMessage('@amigo hola')).toBe(false);
    expect(isSfsMessage('hola como estas')).toBe(false);
  });

  it('con foto basta un @ o un link', () => {
    expect(isSfsWithPhoto('@amigo', true)).toBe(true);
    expect(isSfsWithPhoto('https://x.com', true)).toBe(true);
    expect(isSfsWithPhoto('hola', true)).toBe(false);
    expect(isSfsWithPhoto('@amigo', false)).toBe(false);
  });

  it('peticiones y palabras clave', () => {
    expect(isSfsRequestOnly('s4s?')).toBe(true);
    expect(isSfsRequestOnly('hola')).toBe(false);
    expect(isUseGoKeyword('GO')).toBe(true);
    expect(isUseGoKeyword('google')).toBe(false);
    expect(hasPromoData('t.me/algo')).toBe(true);
  });

  it('firma invisible y username', () => {
    expect(hasSfsSignature(addSfsSignature('hola'))).toBe(true);
    expect(hasSfsSignature('hola')).toBe(false);
    expect(extractUsername(undefined, 'sigan a @mi_canal')).toBe('mi_canal');
    expect(extractUsername('real', '@otro')).toBe('real');
  });
});
