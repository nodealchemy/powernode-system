import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { FulfillmentTab } from './FulfillmentTab';
import type {
  FulfillmentRequestDetail,
  FulfillmentRequestSummary,
} from '../../types/service_delivery.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: jest.fn(),
    delete: jest.fn(),
  },
}));

let mockPermissionGranted = (_perm: string) => true;
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockPermissionGranted(perm),
  }),
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

function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const COMPOSED: FulfillmentRequestSummary = {
  id: 'fr-composed-1',
  state: 'composed',
  request: 'give me a running memcached instance',
  reused_count: 1,
  materialized_count: 0,
  instance_count: 0,
  build_batch_id: null,
  template_id: null,
  node_instance_ids: [],
  expires_at: null,
  error: null,
  parked: null,
  smoke: null,
  approved_at: null,
  approved_by_user_id: null,
  created_at: '2026-09-01T00:00:00Z',
};

const READY: FulfillmentRequestSummary = {
  ...COMPOSED,
  id: 'fr-ready-2',
  state: 'ready',
  request: 'a redis instance',
  materialized_count: 2,
};

const DETAIL: FulfillmentRequestDetail = {
  ...COMPOSED,
  plan: {
    execution: {
      base_os_module_id: 'base-os-id',
      reused_module_ids: ['mod-a'],
      gaps: [{ package: 'memcached' }],
      template_name: 'fulfill-memcached',
    },
    unresolved_gaps: [{ capability: 'memcached-exporter', reason: 'author_module' }],
  },
  plan_digest: 'abc123def456',
  cost_estimate: { monthly_usd: 12.0 },
};

/** An axios-shaped rejection: the server's own sentence lives in response.data.error. */
function apiError(serverSentence?: string) {
  return serverSentence
    ? { response: { data: { error: serverSentence } } }
    : new Error('');
}

function listEnvelope(rows: FulfillmentRequestSummary[], awaiting?: number) {
  return envelope({
    fulfillment_requests: rows,
    awaiting_approval_count:
      awaiting ?? rows.filter((r) => r.state === 'composed').length,
  });
}

function approveEnvelope(overrides: Record<string, unknown> = {}) {
  return envelope({
    fulfillment_request: { ...COMPOSED, state: 'materializing' },
    advance: {
      ok: true,
      state: 'materializing',
      advanced: 1,
      waiting: false,
      parked: null,
      error: null,
      already_advancing: false,
      ...overrides,
    },
  });
}

/** Click Approve and wait for the confirmation to open with the plan loaded. */
async function openApproveDialog() {
  fireEvent.click(await screen.findByRole('button', { name: /Approve/ }));
  await screen.findByText(/Approving releases this plan/);
}

beforeEach(() => {
  jest.clearAllMocks();
  mockPermissionGranted = () => true;
  mockGet.mockResolvedValue(listEnvelope([COMPOSED, READY]));
  mockPost.mockResolvedValue(approveEnvelope());
});

// =============================================================================
// Tests
// =============================================================================

describe('FulfillmentTab', () => {
  describe('list', () => {
    it('lists fulfillment requests from the index endpoint', async () => {
      render(<FulfillmentTab />);
      expect(
        await screen.findByText('give me a running memcached instance'),
      ).toBeInTheDocument();
      expect(screen.getByText('a redis instance')).toBeInTheDocument();
      expect(mockGet).toHaveBeenCalledWith('/system/fulfillment_requests', {
        params: {},
      });
    });

    it('badges how many requests await a human decision', async () => {
      render(<FulfillmentTab />);
      expect(await screen.findByText('1 awaiting approval')).toBeInTheDocument();
    });

    it('renders an empty state when nothing is pending', async () => {
      mockGet.mockResolvedValue(listEnvelope([]));
      render(<FulfillmentTab />);
      expect(await screen.findByText('No fulfillment requests.')).toBeInTheDocument();
    });

    it("surfaces the server's own sentence on a load failure, not an empty list", async () => {
      mockGet.mockRejectedValue(apiError('fulfillment is disabled on this account'));
      render(<FulfillmentTab />);
      expect(
        await screen.findByText('fulfillment is disabled on this account'),
      ).toBeInTheDocument();
      expect(screen.queryByText('No fulfillment requests.')).not.toBeInTheDocument();
    });

    it('falls back to a readable message when the failure carries none', async () => {
      mockGet.mockRejectedValue(apiError());
      render(<FulfillmentTab />);
      expect(
        await screen.findByText('Failed to load fulfillment requests'),
      ).toBeInTheDocument();
    });

    it('says so when composed requests exist beyond the page being shown', async () => {
      // The index paginates; awaiting_approval_count counts every composed row.
      // An unlisted composed request is an unapprovable one, so the gap must be
      // visible rather than a silent disagreement between two numbers.
      mockGet.mockResolvedValue(listEnvelope([COMPOSED, READY], 7));
      render(<FulfillmentTab />);
      expect(await screen.findByText('7 awaiting approval')).toBeInTheDocument();
      expect(screen.getByText('6 not shown on this page')).toBeInTheDocument();
    });

    it('says nothing about hidden rows when the page holds them all', async () => {
      render(<FulfillmentTab />);
      await screen.findByText('1 awaiting approval');
      expect(screen.queryByText(/not shown on this page/)).not.toBeInTheDocument();
    });

    it('offers Approve only for a composed request', async () => {
      render(<FulfillmentTab />);
      await screen.findByText('a redis instance');
      // Two rows, one composed: exactly one Approve button.
      expect(screen.getAllByRole('button', { name: /Approve/ })).toHaveLength(1);
    });

    it('tells a reader without approve permission that someone else must act', async () => {
      mockPermissionGranted = (perm) => perm !== 'system.fulfillment_requests.approve';
      render(<FulfillmentTab />);
      expect(await screen.findByText('awaiting an approver')).toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /Approve/ })).not.toBeInTheDocument();
    });
  });

  describe('approve confirmation', () => {
    it('fetches the FROZEN plan and shows it before approving', async () => {
      mockGet
        .mockResolvedValueOnce(listEnvelope([COMPOSED]))
        .mockResolvedValueOnce(envelope({ fulfillment_request: DETAIL }));
      render(<FulfillmentTab />);
      await openApproveDialog();

      expect(mockGet).toHaveBeenCalledWith('/system/fulfillment_requests/fr-composed-1');
      expect(screen.getByText('fulfill-memcached')).toBeInTheDocument();
      expect(screen.getByText('abc123def456')).toBeInTheDocument();
    });

    it('shows unresolved gaps rather than hiding them from the approver', async () => {
      mockGet
        .mockResolvedValueOnce(listEnvelope([COMPOSED]))
        .mockResolvedValueOnce(envelope({ fulfillment_request: DETAIL }));
      render(<FulfillmentTab />);
      await openApproveDialog();

      expect(screen.getByText('memcached-exporter')).toBeInTheDocument();
      expect(screen.getByText(/could not be/)).toBeInTheDocument();
    });

    it('shows the parks recorded before the request reached the operator', async () => {
      mockGet
        .mockResolvedValueOnce(listEnvelope([COMPOSED]))
        .mockResolvedValueOnce(
          envelope({
            fulfillment_request: {
              ...DETAIL,
              parked: [{ reason: 'autonomous approval withheld' }],
            },
          }),
        );
      render(<FulfillmentTab />);
      await openApproveDialog();

      expect(screen.getByText('autonomous approval withheld')).toBeInTheDocument();
    });

    it('does NOT approve until the operator confirms', async () => {
      mockGet
        .mockResolvedValueOnce(listEnvelope([COMPOSED]))
        .mockResolvedValueOnce(envelope({ fulfillment_request: DETAIL }));
      render(<FulfillmentTab />);
      await openApproveDialog();

      expect(mockPost).not.toHaveBeenCalled();
    });

    it('reports a plan-fetch failure and never opens the dialog', async () => {
      mockGet
        .mockResolvedValueOnce(listEnvelope([COMPOSED]))
        .mockRejectedValueOnce(apiError('plan is no longer readable'));
      render(<FulfillmentTab />);
      fireEvent.click(await screen.findByRole('button', { name: /Approve/ }));

      expect(await screen.findByText('plan is no longer readable')).toBeInTheDocument();
      expect(screen.queryByText(/Approving releases this plan/)).not.toBeInTheDocument();
      expect(mockPost).not.toHaveBeenCalled();
    });
  });

  describe('approve', () => {
    async function confirmApprove() {
      mockGet
        .mockResolvedValueOnce(listEnvelope([COMPOSED]))
        .mockResolvedValueOnce(envelope({ fulfillment_request: DETAIL }))
        .mockResolvedValue(listEnvelope([{ ...COMPOSED, state: 'materializing' }], 0));
      render(<FulfillmentTab />);
      await openApproveDialog();
      fireEvent.click(screen.getByRole('button', { name: /Approve and release the plan/ }));
    }

    it('posts to the approve endpoint on confirm', async () => {
      await confirmApprove();
      await waitFor(() =>
        expect(mockPost).toHaveBeenCalledWith(
          '/system/fulfillment_requests/fr-composed-1/approve',
          {},
        ),
      );
    });

    it('reports the state the inline advance reached', async () => {
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'success',
            message: expect.stringContaining('materializing'),
          }),
        ),
      );
    });

    // `parked` is a CUMULATIVE trail: a request that reached the operator queue
    // because autonomous approval was withheld already carries a park before the
    // approval happens. Treating a non-empty trail as "this advance parked"
    // would warn on every ordinary success.
    it('does not downgrade a successful advance because of a pre-existing park trail', async () => {
      mockPost.mockResolvedValue(
        approveEnvelope({
          parked: [{ step: 'autonomous_approval', reason: 'confidence below threshold' }],
        }),
      );
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'success' }),
        ),
      );
      expect(mockAddNotification).not.toHaveBeenCalledWith(
        expect.objectContaining({ type: 'warning' }),
      );
    });

    // park_gate! sets `error` alongside the park, so the gate is what `error`
    // reports — the budget/rate-limit case the operator must actually see.
    it('warns when the budget or rate-limit gate parked the advance', async () => {
      mockPost.mockResolvedValue(
        approveEnvelope({
          state: 'approved',
          error: 'monthly budget cap reached',
          parked: [{ step: 'budget_gate', reason: 'monthly budget cap reached' }],
        }),
      );
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'warning',
            message: expect.stringContaining('monthly budget cap reached'),
          }),
        ),
      );
    });

    it('warns rather than claiming success when ok is false with no sentence', async () => {
      mockPost.mockResolvedValue(approveEnvelope({ ok: false, error: null }));
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'warning' }),
        ),
      );
      expect(mockAddNotification).not.toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success' }),
      );
    });

    it('warns rather than claiming success when the advance errored', async () => {
      mockPost.mockResolvedValue(approveEnvelope({ ok: false, error: 'rate limited' }));
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'warning',
            message: expect.stringContaining('rate limited'),
          }),
        ),
      );
    });

    // The dual-plane fence can still park an operator approval behind a second
    // approval. Reporting that as "approved" would be a lie about a governance
    // decision, so it must read as pending.
    it('reports a 202 pending-approval as pending, never as approved', async () => {
      mockPost.mockResolvedValue(
        envelope({
          pending: true,
          deferred_operation_id: 'op-1',
          action_category: 'fulfillment.approve',
          approval_request_id: 'ar-1',
          message: 'Parked pending approval',
        }),
      );
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'info', message: 'Parked pending approval' }),
        ),
      );
      expect(mockAddNotification).not.toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success' }),
      );
    });

    it('surfaces an approve failure as an error notification', async () => {
      mockPost.mockRejectedValue(new Error('server said no'));
      await confirmApprove();
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error' }),
        ),
      );
    });

    it('refreshes the list after a successful approve', async () => {
      await confirmApprove();
      // A count would survive a mutation that fetched the detail twice and
      // skipped the refresh; pin that the third call is the LIST call.
      await waitFor(() =>
        expect(mockGet).toHaveBeenNthCalledWith(3, '/system/fulfillment_requests', {
          params: {},
        }),
      );
    });
  });
});
