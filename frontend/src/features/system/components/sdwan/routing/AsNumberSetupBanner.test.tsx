import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { AsNumberSetupBanner } from './AsNumberSetupBanner';
import type { SdwanAccountBgp } from '../../../types/sdwan.types';

// =============================================================================
// Mocks
// =============================================================================

const mockAllocateAccountAs = jest.fn();

jest.mock('@system/features/system/services/api/sdwanApi', () => ({
  sdwanApi: {
    allocateAccountAs: (...args: unknown[]) => mockAllocateAccountAs(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// =============================================================================
// Fixtures
// =============================================================================

const ACCOUNT_BGP: SdwanAccountBgp = {
  id: 'bgp-uuid-1',
  as_number: 4200000042,
  router_id_strategy: 'peer_overlay_ipv6_hash',
  default_local_pref: 100,
  enabled: true,
  created_at: '2026-01-01T00:00:00Z',
};

// =============================================================================
// Tests
// =============================================================================

describe('AsNumberSetupBanner', () => {
  beforeEach(() => {
    mockAllocateAccountAs.mockReset();
    mockAddNotification.mockReset();
  });

  // ── Allocated state ────────────────────────────────────────────────────────

  describe('when accountBgp is provided (allocated state)', () => {
    it('renders the success banner with AS number and router-id strategy', () => {
      render(
        <AsNumberSetupBanner accountBgp={ACCOUNT_BGP} canManage />,
      );

      expect(screen.getByText(/Account AS allocated:/i)).toBeInTheDocument();
      expect(screen.getByText('4200000042')).toBeInTheDocument();
      expect(screen.getByText('peer_overlay_ipv6_hash')).toBeInTheDocument();
    });

    it('shows the iBGP informational copy in the success state', () => {
      render(<AsNumberSetupBanner accountBgp={ACCOUNT_BGP} />);
      expect(
        screen.getByText(/All iBGP networks in this account share this AS number/i),
      ).toBeInTheDocument();
    });

    it('does not render the Allocate AS button when already allocated', () => {
      render(<AsNumberSetupBanner accountBgp={ACCOUNT_BGP} canManage />);
      expect(screen.queryByRole('button', { name: /allocate as/i })).not.toBeInTheDocument();
    });

    it('does not render the "No AS number allocated" heading', () => {
      render(<AsNumberSetupBanner accountBgp={ACCOUNT_BGP} canManage />);
      expect(screen.queryByText(/No AS number allocated/i)).not.toBeInTheDocument();
    });
  });

  // ── Unallocated state ──────────────────────────────────────────────────────

  describe('when accountBgp is null (unallocated state)', () => {
    it('renders the warning banner with "No AS number allocated" heading', () => {
      render(<AsNumberSetupBanner accountBgp={null} />);
      expect(screen.getByText('No AS number allocated')).toBeInTheDocument();
    });

    it('shows the RFC 6996 informational copy', () => {
      render(<AsNumberSetupBanner accountBgp={null} />);
      expect(
        screen.getByText(/RFC 6996/i),
      ).toBeInTheDocument();
    });

    it('does not render the Allocate AS button when canManage is false (default)', () => {
      render(<AsNumberSetupBanner accountBgp={null} />);
      expect(screen.queryByRole('button', { name: /allocate as/i })).not.toBeInTheDocument();
    });

    it('renders the Allocate AS button when canManage is true', () => {
      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      expect(screen.getByRole('button', { name: /allocate as/i })).toBeInTheDocument();
    });

    it('does not render an error message initially', () => {
      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      expect(screen.queryByText(/AS allocation failed/i)).not.toBeInTheDocument();
    });
  });

  // ── Allocation flow ────────────────────────────────────────────────────────

  describe('Allocate AS button interaction', () => {
    it('disables the button and shows "Allocating…" text while the request is in-flight', async () => {
      // Never-resolving promise keeps the loading state visible.
      mockAllocateAccountAs.mockReturnValue(new Promise(() => {}));

      render(<AsNumberSetupBanner accountBgp={null} canManage />);

      const btn = screen.getByRole('button', { name: /allocate as/i });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /Allocating…/i })).toBeDisabled(),
      );
    });

    it('calls sdwanApi.allocateAccountAs with no arguments on click', async () => {
      mockAllocateAccountAs.mockResolvedValue({
        account_bgp: ACCOUNT_BGP,
        allocated: true,
      });

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      fireEvent.click(screen.getByRole('button', { name: /allocate as/i }));

      await waitFor(() => expect(mockAllocateAccountAs).toHaveBeenCalledTimes(1));
      expect(mockAllocateAccountAs).toHaveBeenCalledWith();
    });

    it('invokes onAllocated with the returned account_bgp on success', async () => {
      const onAllocated = jest.fn();
      mockAllocateAccountAs.mockResolvedValue({
        account_bgp: ACCOUNT_BGP,
        allocated: true,
      });

      render(
        <AsNumberSetupBanner accountBgp={null} canManage onAllocated={onAllocated} />,
      );
      fireEvent.click(screen.getByRole('button', { name: /allocate as/i }));

      await waitFor(() => expect(onAllocated).toHaveBeenCalledWith(ACCOUNT_BGP));
    });

    it('re-enables the button after a successful allocation', async () => {
      mockAllocateAccountAs.mockResolvedValue({
        account_bgp: ACCOUNT_BGP,
        allocated: true,
      });

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      const btn = screen.getByRole('button', { name: /allocate as/i });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /allocate as/i })).not.toBeDisabled(),
      );
    });

    it('does not call onAllocated when onAllocated is not provided (no crash)', async () => {
      mockAllocateAccountAs.mockResolvedValue({
        account_bgp: ACCOUNT_BGP,
        allocated: true,
      });

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      fireEvent.click(screen.getByRole('button', { name: /allocate as/i }));

      // Just verifies it resolves without throwing.
      await waitFor(() => expect(mockAllocateAccountAs).toHaveBeenCalledTimes(1));
    });
  });

  // ── Error handling ─────────────────────────────────────────────────────────

  describe('allocation error handling', () => {
    it('displays the error message when allocation throws an Error', async () => {
      mockAllocateAccountAs.mockRejectedValue(new Error('BGP quota exceeded'));

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      fireEvent.click(screen.getByRole('button', { name: /allocate as/i }));

      await waitFor(() =>
        expect(screen.getByText('BGP quota exceeded')).toBeInTheDocument(),
      );
    });

    it('displays a fallback message when a non-Error is thrown', async () => {
      mockAllocateAccountAs.mockRejectedValue('plain string error');

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      fireEvent.click(screen.getByRole('button', { name: /allocate as/i }));

      await waitFor(() =>
        expect(screen.getByText('AS allocation failed')).toBeInTheDocument(),
      );
    });

    it('re-enables the button after a failed allocation', async () => {
      mockAllocateAccountAs.mockRejectedValue(new Error('network error'));

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      const btn = screen.getByRole('button', { name: /allocate as/i });
      fireEvent.click(btn);

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /allocate as/i })).not.toBeDisabled(),
      );
    });

    it('clears a previous error when Allocate AS is clicked again', async () => {
      // First call fails.
      mockAllocateAccountAs.mockRejectedValueOnce(new Error('timeout'));
      // Second call is in-flight (never resolves) — error should be gone.
      mockAllocateAccountAs.mockReturnValueOnce(new Promise(() => {}));

      render(<AsNumberSetupBanner accountBgp={null} canManage />);
      const btn = screen.getByRole('button', { name: /allocate as/i });

      // First click — error appears.
      fireEvent.click(btn);
      await waitFor(() => expect(screen.getByText('timeout')).toBeInTheDocument());

      // Second click — error is cleared immediately.
      fireEvent.click(btn);
      await waitFor(() =>
        expect(screen.queryByText('timeout')).not.toBeInTheDocument(),
      );
    });
  });

  // ── Pending-approval branch (IMP-87ec6f651f07) ─────────────────────────────

  describe('pending-approval branch', () => {
    const PENDING_APPROVAL = {
      pending: true,
      deferred_operation_id: 'dop-1',
      action_category: 'sdwan.account_as_allocate',
      approval_request_id: 'ar-1',
      message: 'Approval required',
    };

    it('shows the pending-approval notification and does not call onAllocated', async () => {
      mockAllocateAccountAs.mockResolvedValue(PENDING_APPROVAL);
      const onAllocated = jest.fn();

      render(<AsNumberSetupBanner accountBgp={null} canManage onAllocated={onAllocated} />);
      fireEvent.click(screen.getByRole('button', { name: /allocate as/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'info',
            message: expect.stringMatching(/approval required/i),
            link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
          }),
        ),
      );
      expect(onAllocated).not.toHaveBeenCalled();
    });
  });
});
