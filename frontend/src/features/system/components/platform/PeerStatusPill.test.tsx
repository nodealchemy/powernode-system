import React from 'react';
import { render, screen } from '@testing-library/react';
import { PeerStatusPill } from './PeerStatusPill';
import type { PeerStatus } from '../../types/peer.types';

// PeerStatusPill is a pure presentational component — no API calls, no hooks,
// no user interactions. Tests cover:
//   1. Each PeerStatus value renders its label text.
//   2. Each status gets the correct theme CSS classes (background + text).
//   3. The structural classes are always applied (inline-block, px-2, etc.).

const ALL_STATUSES: PeerStatus[] = [
  'proposed',
  'accepted',
  'enrolled',
  'active',
  'degraded',
  'suspended',
  'revoked',
];

// Expected CSS class fragments per status, derived directly from STYLE_BY_STATUS
// in PeerStatusPill.tsx.
const EXPECTED_CLASSES: Record<PeerStatus, { bg: string; text: string }> = {
  proposed: { bg: 'bg-theme-background-tertiary', text: 'text-theme-secondary' },
  accepted: { bg: 'bg-theme-info', text: 'text-theme-info' },
  enrolled: { bg: 'bg-theme-info', text: 'text-theme-info' },
  active: { bg: 'bg-theme-success', text: 'text-theme-success' },
  degraded: { bg: 'bg-theme-warning', text: 'text-theme-warning' },
  suspended: { bg: 'bg-theme-warning', text: 'text-theme-warning' },
  revoked: { bg: 'bg-theme-danger', text: 'text-theme-danger' },
};

// Structural classes that must be present for every status.
const STRUCTURAL_CLASSES = ['inline-block', 'px-2', 'py-0.5', 'rounded', 'text-xs', 'font-medium'];

describe('PeerStatusPill', () => {
  ALL_STATUSES.forEach((status) => {
    describe(`status="${status}"`, () => {
      let pill: HTMLElement;

      beforeEach(() => {
        const { unmount } = render(<PeerStatusPill status={status} />);
        pill = screen.getByText(status);
        return unmount;
      });

      it('renders the status label text', () => {
        expect(pill).toBeInTheDocument();
        expect(pill).toHaveTextContent(status);
      });

      it('renders as a <span> element', () => {
        expect(pill.tagName).toBe('SPAN');
      });

      it('applies the correct background theme class', () => {
        expect(pill).toHaveClass(EXPECTED_CLASSES[status].bg);
      });

      it('applies the correct text theme class', () => {
        expect(pill).toHaveClass(EXPECTED_CLASSES[status].text);
      });

      it('applies all structural classes', () => {
        STRUCTURAL_CLASSES.forEach((cls) => {
          expect(pill).toHaveClass(cls);
        });
      });
    });
  });

  it('covers every PeerStatus value in the style map (no unknown status renders undefined class)', () => {
    // Render each status and verify className is a non-empty string
    // with no "undefined" token (which would appear if a status was
    // missing from STYLE_BY_STATUS).
    ALL_STATUSES.forEach((status) => {
      const { unmount } = render(<PeerStatusPill status={status} />);
      const el = screen.getByText(status);
      expect(el.className).not.toContain('undefined');
      expect(el.className.length).toBeGreaterThan(0);
      unmount();
    });
  });

  it('accepted and enrolled share the same info theme classes', () => {
    const { unmount: unmountA } = render(<PeerStatusPill status="accepted" />);
    const accepted = screen.getByText('accepted');
    const { unmount: unmountE } = render(<PeerStatusPill status="enrolled" />);
    const enrolled = screen.getByText('enrolled');

    expect(accepted.className).toBe(enrolled.className);

    unmountA();
    unmountE();
  });

  it('degraded and suspended share the same warning theme classes', () => {
    const { unmount: unmountD } = render(<PeerStatusPill status="degraded" />);
    const degraded = screen.getByText('degraded');
    const { unmount: unmountS } = render(<PeerStatusPill status="suspended" />);
    const suspended = screen.getByText('suspended');

    expect(degraded.className).toBe(suspended.className);

    unmountD();
    unmountS();
  });

  it('active has a distinct class from degraded (success vs warning)', () => {
    const { unmount: unmountA } = render(<PeerStatusPill status="active" />);
    const active = screen.getByText('active');
    const { unmount: unmountD } = render(<PeerStatusPill status="degraded" />);
    const degraded = screen.getByText('degraded');

    expect(active.className).not.toBe(degraded.className);

    unmountA();
    unmountD();
  });

  it('revoked has a distinct class from all non-danger statuses', () => {
    const nonDangerStatuses: PeerStatus[] = ['proposed', 'accepted', 'enrolled', 'active', 'degraded', 'suspended'];
    const { unmount: unmountR } = render(<PeerStatusPill status="revoked" />);
    const revoked = screen.getByText('revoked');
    const revokedClass = revoked.className;
    unmountR();

    nonDangerStatuses.forEach((status) => {
      const { unmount } = render(<PeerStatusPill status={status} />);
      const el = screen.getByText(status);
      expect(el.className).not.toBe(revokedClass);
      unmount();
    });
  });
});
