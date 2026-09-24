import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { RoutePolicyEditModal } from './RoutePolicyEditModal';
import { APPROVALS_SURFACE_PATH } from '@system/features/system/utils/pendingApproval';
import type { SdwanRoutePolicy } from '@system/features/system/types/sdwan.types';

// =============================================================================
// Mocks
//
// The component calls sdwanApi.getRoutePolicy (on edit without statements),
// sdwanApi.createRoutePolicy, and sdwanApi.updateRoutePolicy. We mock the
// sdwanApi facade and the notification hook.
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPatch = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
  },
}));

const mockHasPermission = jest.fn().mockReturnValue(true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (perm: string) => mockHasPermission(perm),
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

/** Double-envelope helper — mirrors the real AxiosResponse<ApiEnvelope<T>> shape. */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

const POLICY_WITH_STATEMENTS: SdwanRoutePolicy = {
  id: 'policy-1',
  name: 'prefer-internal',
  description: 'Prefer internal routes',
  scope: 'account',
  scope_resource_id: null,
  direction: 'import',
  enabled: true,
  statement_count: 1,
  slug: 'prefer-internal',
  statements: [
    {
      match: { prefix_in: ['192.168.0.0/16'] },
      action: { type: 'accept', set_local_pref: 100 },
    },
  ],
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const POLICY_WITHOUT_STATEMENTS: SdwanRoutePolicy = {
  id: 'policy-2',
  name: 'block-external',
  description: null,
  scope: 'network',
  scope_resource_id: 'net-uuid-123',
  direction: 'export',
  enabled: false,
  statement_count: 2,
  slug: 'block-external',
  // statements intentionally omitted (as list endpoint does)
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const DEFAULT_STATEMENTS_JSON = JSON.stringify(
  [{ match: { prefix_in: ['10.0.0.0/8'] }, action: { type: 'accept', set_local_pref: 200 } }],
  null,
  2
);

// =============================================================================
// Test helpers
// =============================================================================

const mockOnClose = jest.fn();
const mockOnSaved = jest.fn();

function renderModal(policy?: SdwanRoutePolicy | null) {
  return render(
    <BrowserRouter>
      <RoutePolicyEditModal
        policy={policy}
        onClose={mockOnClose}
        onSaved={mockOnSaved}
      />
    </BrowserRouter>
  );
}

// =============================================================================
// Tests
// =============================================================================

describe('RoutePolicyEditModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPatch.mockReset();
    mockAddNotification.mockReset();
    mockHasPermission.mockReset();
    mockHasPermission.mockReturnValue(true);
    mockOnClose.mockReset();
    mockOnSaved.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Create mode — rendering
  // ---------------------------------------------------------------------------

  describe('create mode (no policy prop)', () => {
    it('renders the "New route policy" title', () => {
      renderModal();
      expect(screen.getByText('New route policy')).toBeInTheDocument();
    });

    it('renders a "Create policy" submit button', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /create policy/i })).toBeInTheDocument();
    });

    it('initialises the name field as empty', () => {
      renderModal();
      const nameInput = screen.getByPlaceholderText(/prefer-internal-routes/i);
      expect(nameInput).toHaveValue('');
    });

    it('initialises the direction select to "import"', () => {
      renderModal();
      const select = screen.getByDisplayValue(/import/i);
      expect(select).toBeInTheDocument();
    });

    it('initialises the scope select to "account"', () => {
      renderModal();
      // "account" option text contains "(every iBGP neighbor)"
      expect(screen.getByDisplayValue(/account/i)).toBeInTheDocument();
    });

    it('does NOT render the scope resource ID field when scope is account', () => {
      renderModal();
      expect(screen.queryByPlaceholderText('UUID')).not.toBeInTheDocument();
    });

    it('pre-fills the statements textarea with the default example', () => {
      renderModal();
      // The textarea has no accessible name (label is not associated via htmlFor/id),
      // so select it by element type directly.
      const textarea = document.querySelector('textarea') as HTMLTextAreaElement;
      expect(textarea).toHaveValue(DEFAULT_STATEMENTS_JSON);
    });

    it('checks the "Enabled" checkbox by default', () => {
      renderModal();
      expect(screen.getByRole('checkbox', { name: /enabled/i })).toBeChecked();
    });

    it('does NOT call sdwanApi on initial render', () => {
      renderModal();
      expect(mockGet).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode — rendering
  // ---------------------------------------------------------------------------

  describe('edit mode (policy with statements)', () => {
    it('renders the edit title with the policy name', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByText(`Edit policy — ${POLICY_WITH_STATEMENTS.name}`)).toBeInTheDocument();
    });

    it('renders a "Save changes" submit button', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByRole('button', { name: /save changes/i })).toBeInTheDocument();
    });

    it('pre-fills the name field with the policy name', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByPlaceholderText(/prefer-internal-routes/i)).toHaveValue(POLICY_WITH_STATEMENTS.name);
    });

    it('pre-fills the description field with the policy description', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      // Description is the second text input (after name); labels are not associated
      // with htmlFor/id in the component so we select by position.
      const inputs = document.querySelectorAll('input[type="text"]');
      const descInput = inputs[1] as HTMLInputElement;
      expect(descInput).toHaveValue(POLICY_WITH_STATEMENTS.description as string);
    });

    it('pre-fills the direction select', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByDisplayValue(/import \(inbound/i)).toBeInTheDocument();
    });

    it('pre-fills statements from the policy statements prop', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      const textarea = document.querySelector('textarea') as HTMLTextAreaElement;
      expect(textarea).toHaveValue(JSON.stringify(POLICY_WITH_STATEMENTS.statements, null, 2));
    });

    it('shows the enabled checkbox as checked when policy.enabled=true', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByRole('checkbox', { name: /enabled/i })).toBeChecked();
    });

    it('does NOT fetch statements when they are already on the policy object', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(mockGet).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode — statements fetched from API when missing
  // ---------------------------------------------------------------------------

  describe('edit mode (policy without statements — triggers fetch)', () => {
    it('fetches statements from the API and renders them in the textarea', async () => {
      const fetchedPolicy: SdwanRoutePolicy = {
        ...POLICY_WITHOUT_STATEMENTS,
        statements: [
          { match: { prefix_in: ['172.16.0.0/12'] }, action: { type: 'reject' } },
        ],
      };
      mockGet.mockResolvedValueOnce(
        envelope({ route_policy: fetchedPolicy })
      );

      renderModal(POLICY_WITHOUT_STATEMENTS);

      await waitFor(() => {
        const textarea = document.querySelector('textarea') as HTMLTextAreaElement;
        expect(textarea).toHaveValue(JSON.stringify(fetchedPolicy.statements, null, 2));
      });

      expect(mockGet).toHaveBeenCalledWith(
        `/system/sdwan/route_policies/${POLICY_WITHOUT_STATEMENTS.id}`
      );
    });

    it('surfaces an inline error when the fetch fails', async () => {
      mockGet.mockRejectedValueOnce(new Error('network error'));
      renderModal(POLICY_WITHOUT_STATEMENTS);
      expect(await screen.findByText(/could not load the current statements/i)).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit mode — the backfill gates Save (IMP-07502ddfb8cf)
  //
  // The list endpoint omits statements, so on edit the modal must never seed the
  // textarea with DEFAULT_STATEMENTS nor let an operator save before the real
  // statements have been fetched. Saving early replaced the live BGP policy with
  // the placeholder "10.0.0.0/8 accept set_local_pref 200".
  // ---------------------------------------------------------------------------

  describe('edit mode — statements backfill gates Save', () => {
    /** A getRoutePolicy promise we resolve/reject by hand, to hold the backfill pending. */
    function deferredGet() {
      let settle!: (value: unknown) => void;
      let fail!: (reason: unknown) => void;
      const promise = new Promise((resolve, reject) => {
        settle = resolve;
        fail = reject;
      });
      mockGet.mockReturnValueOnce(promise);
      return { settle, fail };
    }

    it('does NOT seed the textarea with DEFAULT_STATEMENTS while the backfill is pending', () => {
      deferredGet();
      renderModal(POLICY_WITHOUT_STATEMENTS);
      const textarea = document.querySelector('textarea') as HTMLTextAreaElement;
      expect(textarea).not.toHaveValue(DEFAULT_STATEMENTS_JSON);
    });

    it('keeps Save disabled while the backfill is pending', () => {
      deferredGet();
      renderModal(POLICY_WITHOUT_STATEMENTS);
      expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
    });

    it('does NOT issue the update when submitted while the backfill is pending', async () => {
      deferredGet();
      renderModal(POLICY_WITHOUT_STATEMENTS);

      // Submit the form directly — the disabled button is not the only entry point
      // (Enter in a text field submits too).
      fireEvent.submit(document.querySelector('form') as HTMLFormElement);

      await waitFor(() => {
        expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
      });
      expect(mockPatch).not.toHaveBeenCalled();
    });

    it('enables Save and submits the FETCHED statements once the backfill resolves', async () => {
      const fetchedStatements = [
        { match: { prefix_in: ['172.16.0.0/12'] }, action: { type: 'reject' } },
      ];
      const { settle } = deferredGet();
      mockPatch.mockResolvedValueOnce(
        envelope({ route_policy: { ...POLICY_WITHOUT_STATEMENTS, statements: fetchedStatements } })
      );

      renderModal(POLICY_WITHOUT_STATEMENTS);

      // Disabled BEFORE the backfill settles — without this the assertion below
      // would hold even on code that never gated Save at all.
      expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();

      await act(async () => {
        settle(envelope({ route_policy: { ...POLICY_WITHOUT_STATEMENTS, statements: fetchedStatements } }));
      });

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /save changes/i })).toBeEnabled()
      );

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() => expect(mockPatch).toHaveBeenCalled());
      const [, body] = mockPatch.mock.calls[0] as [string, { route_policy: Record<string, unknown> }];
      expect(body.route_policy.statements).toEqual(fetchedStatements);
    });

    it('keeps Save disabled and never issues the update after the backfill FAILS', async () => {
      mockGet.mockRejectedValueOnce(new Error('network error'));
      renderModal(POLICY_WITHOUT_STATEMENTS);

      expect(await screen.findByText(/could not load the current statements/i)).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();

      fireEvent.submit(document.querySelector('form') as HTMLFormElement);

      await waitFor(() => {
        expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
      });
      expect(mockPatch).not.toHaveBeenCalled();
    });

    it('treats a response with no statements as a failed backfill rather than an empty policy', async () => {
      mockGet.mockResolvedValueOnce(
        envelope({ route_policy: { ...POLICY_WITHOUT_STATEMENTS } })
      );
      renderModal(POLICY_WITHOUT_STATEMENTS);

      expect(await screen.findByText(/could not load the current statements/i)).toBeInTheDocument();
      expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();
    });

    it('does not gate Save in CREATE mode (no backfill is needed)', () => {
      renderModal();
      expect(screen.getByRole('button', { name: /create policy/i })).toBeEnabled();
      expect(mockGet).not.toHaveBeenCalled();
    });

    it('does not gate Save when the policy already carries its statements', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByRole('button', { name: /save changes/i })).toBeEnabled();
      expect(mockGet).not.toHaveBeenCalled();
    });

    it('releases the gate if the policy prop later arrives WITH its statements', async () => {
      deferredGet();
      const { rerender } = render(
        <BrowserRouter>
          <RoutePolicyEditModal policy={POLICY_WITHOUT_STATEMENTS} onClose={mockOnClose} onSaved={mockOnSaved} />
        </BrowserRouter>
      );
      expect(screen.getByRole('button', { name: /save changes/i })).toBeDisabled();

      // A caller that reuses this instance rather than remounting it must not be
      // left with a permanently dead form.
      rerender(
        <BrowserRouter>
          <RoutePolicyEditModal policy={POLICY_WITH_STATEMENTS} onClose={mockOnClose} onSaved={mockOnSaved} />
        </BrowserRouter>
      );

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /save changes/i })).toBeEnabled()
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Scope field — conditional rendering
  // ---------------------------------------------------------------------------

  describe('scope conditional field', () => {
    it('shows "Network ID" input when scope is changed to "network"', async () => {
      renderModal();
      // Scope is the second <select> (direction is first); labels are not associated via htmlFor/id
      const selects = screen.getAllByRole('combobox');
      const scopeSelect = selects[1]; // direction=0, scope=1
      fireEvent.change(scopeSelect, { target: { value: 'network' } });
      expect(await screen.findByText(/^network id$/i)).toBeInTheDocument();
      expect(screen.getByPlaceholderText('UUID')).toBeInTheDocument();
    });

    it('shows "Peer ID" input when scope is changed to "peer"', async () => {
      renderModal();
      const selects = screen.getAllByRole('combobox');
      const scopeSelect = selects[1];
      fireEvent.change(scopeSelect, { target: { value: 'peer' } });
      expect(await screen.findByText(/^peer id$/i)).toBeInTheDocument();
      expect(screen.getByPlaceholderText('UUID')).toBeInTheDocument();
    });

    it('hides the resource ID field again when scope is switched back to account', async () => {
      renderModal();
      const selects = screen.getAllByRole('combobox');
      const scopeSelect = selects[1];
      fireEvent.change(scopeSelect, { target: { value: 'network' } });
      expect(await screen.findByPlaceholderText('UUID')).toBeInTheDocument();

      fireEvent.change(scopeSelect, { target: { value: 'account' } });
      expect(screen.queryByPlaceholderText('UUID')).not.toBeInTheDocument();
    });

    it('pre-fills scope=network and Network ID from policy', () => {
      renderModal(POLICY_WITHOUT_STATEMENTS);
      // scope=network pre-fills, so UUID input should be present
      expect(screen.getByPlaceholderText('UUID')).toHaveValue(POLICY_WITHOUT_STATEMENTS.scope_resource_id as string);
    });
  });

  // ---------------------------------------------------------------------------
  // Create — successful submit
  // ---------------------------------------------------------------------------

  describe('create — successful submit', () => {
    it('calls createRoutePolicy with correct payload and invokes onSaved', async () => {
      const created: SdwanRoutePolicy = {
        id: 'new-policy',
        name: 'my-new-policy',
        description: undefined,
        scope: 'account',
        scope_resource_id: null,
        direction: 'import',
        enabled: true,
        statement_count: 1,
        slug: 'my-new-policy',
        statements: [{ match: { prefix_in: ['10.0.0.0/8'] }, action: { type: 'accept', set_local_pref: 200 } }],
      };
      mockPost.mockResolvedValueOnce(envelope({ route_policy: created }));

      renderModal();

      // Fill in the name
      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'my-new-policy' },
      });

      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() => expect(mockOnSaved).toHaveBeenCalledWith(created));

      expect(mockPost).toHaveBeenCalledWith(
        '/system/sdwan/route_policies',
        {
          route_policy: {
            name: 'my-new-policy',
            description: undefined,
            scope: 'account',
            scope_resource_id: null,
            direction: 'import',
            enabled: true,
            statements: [{ match: { prefix_in: ['10.0.0.0/8'] }, action: { type: 'accept', set_local_pref: 200 } }],
          },
        }
      );
    });

    it('sends scope_resource_id when scope is network', async () => {
      const created: SdwanRoutePolicy = {
        id: 'net-policy',
        name: 'net-filter',
        scope: 'network',
        scope_resource_id: 'net-uuid-456',
        direction: 'export',
        enabled: true,
        statement_count: 1,
        slug: 'net-filter',
      };
      mockPost.mockResolvedValueOnce(envelope({ route_policy: created }));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'net-filter' },
      });

      // Scope is the second <select> (direction=0, scope=1); labels not linked via htmlFor
      const scopeSelect = screen.getAllByRole('combobox')[1];
      fireEvent.change(scopeSelect, { target: { value: 'network' } });

      const resourceInput = await screen.findByPlaceholderText('UUID');
      fireEvent.change(resourceInput, { target: { value: 'net-uuid-456' } });

      const dirSelect = screen.getAllByRole('combobox')[0]; // direction is first select
      fireEvent.change(dirSelect, { target: { value: 'export' } });

      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() => expect(mockPost).toHaveBeenCalled());

      const [, body] = mockPost.mock.calls[0] as [string, { route_policy: Record<string, unknown> }];
      expect(body.route_policy.scope).toBe('network');
      expect(body.route_policy.scope_resource_id).toBe('net-uuid-456');
      expect(body.route_policy.direction).toBe('export');
    });

    it('submits scope_resource_id=null when scope is account (even if scopeResourceId field had a value before)', async () => {
      const created: SdwanRoutePolicy = {
        id: 'acct-policy',
        name: 'acct-filter',
        scope: 'account',
        scope_resource_id: null,
        direction: 'import',
        enabled: true,
        statement_count: 1,
        slug: 'acct-filter',
      };
      mockPost.mockResolvedValueOnce(envelope({ route_policy: created }));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'acct-filter' },
      });

      // Scope stays at default 'account'
      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() => expect(mockPost).toHaveBeenCalled());

      const [, body] = mockPost.mock.calls[0] as [string, { route_policy: Record<string, unknown> }];
      expect(body.route_policy.scope_resource_id).toBeNull();
    });
  });

  // ---------------------------------------------------------------------------
  // Edit — successful submit
  // ---------------------------------------------------------------------------

  describe('edit — successful submit', () => {
    it('calls updateRoutePolicy via PATCH with correct payload and invokes onSaved', async () => {
      const updated: SdwanRoutePolicy = { ...POLICY_WITH_STATEMENTS, name: 'updated-name' };
      mockPatch.mockResolvedValueOnce(envelope({ route_policy: updated }));

      renderModal(POLICY_WITH_STATEMENTS);

      // Change the name
      const nameInput = screen.getByPlaceholderText(/prefer-internal-routes/i);
      fireEvent.change(nameInput, { target: { value: 'updated-name' } });

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() => expect(mockOnSaved).toHaveBeenCalledWith(updated));

      expect(mockPatch).toHaveBeenCalledWith(
        `/system/sdwan/route_policies/${POLICY_WITH_STATEMENTS.id}`,
        {
          route_policy: expect.objectContaining({
            name: 'updated-name',
            scope: 'account',
            scope_resource_id: null,
            direction: 'import',
            enabled: true,
          }),
        }
      );
    });

    it('disables the submit button while saving and re-enables on completion', async () => {
      let resolvePost!: (v: unknown) => void;
      const pending = new Promise((r) => { resolvePost = r; });
      mockPatch.mockReturnValueOnce(pending);

      renderModal(POLICY_WITH_STATEMENTS);

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      // While saving the button label changes to "Saving…" and is disabled
      expect(screen.getByRole('button', { name: /saving/i })).toBeDisabled();

      resolvePost(envelope({ route_policy: POLICY_WITH_STATEMENTS }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /save changes/i })).not.toBeDisabled()
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Validation — invalid JSON
  // ---------------------------------------------------------------------------

  describe('statements JSON validation', () => {
    it('shows an error notification when statements contains invalid JSON', async () => {
      renderModal();

      // Fill the required name field so native HTML validation doesn't block submit
      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'test-policy' },
      });

      // The textarea has no accessible name (no htmlFor/id link); select by element type
      const textarea = document.querySelector('textarea') as HTMLTextAreaElement;
      fireEvent.change(textarea, { target: { value: '{invalid json}' } });

      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error' })
        )
      );

      // No API call should have been made
      expect(mockPost).not.toHaveBeenCalled();
    });

    it('shows an error notification when statements JSON is not an array', async () => {
      renderModal();

      // Fill the required name field so native HTML validation doesn't block submit
      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'test-policy' },
      });

      const textarea = document.querySelector('textarea') as HTMLTextAreaElement;
      fireEvent.change(textarea, { target: { value: '{"match":{}}' } });

      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'error',
            message: expect.stringContaining('statements must be a JSON array'),
          })
        )
      );

      expect(mockPost).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // API error handling
  // ---------------------------------------------------------------------------

  describe('API error handling', () => {
    it('shows an error notification when create fails', async () => {
      mockPost.mockRejectedValueOnce(new Error('Server error'));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'broken-policy' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Server error' })
        )
      );
    });

    it('shows a generic error when update throws a non-Error', async () => {
      mockPatch.mockRejectedValueOnce('unexpected string error');

      renderModal(POLICY_WITH_STATEMENTS);

      fireEvent.click(screen.getByRole('button', { name: /save changes/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Save failed' })
        )
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel button
  // ---------------------------------------------------------------------------

  describe('cancel button', () => {
    it('calls onClose when the Cancel button is clicked', () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(mockOnClose).toHaveBeenCalledTimes(1);
    });

    it('does not submit the form when Cancel is clicked', () => {
      renderModal();
      fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
      expect(mockPost).not.toHaveBeenCalled();
      expect(mockPatch).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Enabled checkbox
  // ---------------------------------------------------------------------------

  describe('enabled checkbox', () => {
    it('submits enabled=false when unchecked', async () => {
      const created: SdwanRoutePolicy = {
        id: 'disabled-policy',
        name: 'draft-policy',
        scope: 'account',
        scope_resource_id: null,
        direction: 'import',
        enabled: false,
        statement_count: 1,
        slug: 'draft-policy',
      };
      mockPost.mockResolvedValueOnce(envelope({ route_policy: created }));

      renderModal();

      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'draft-policy' },
      });

      // Uncheck the enabled checkbox
      const enabledCheckbox = screen.getByRole('checkbox', { name: /enabled/i });
      fireEvent.click(enabledCheckbox);
      expect(enabledCheckbox).not.toBeChecked();

      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() => expect(mockPost).toHaveBeenCalled());

      const [, body] = mockPost.mock.calls[0] as [string, { route_policy: Record<string, unknown> }];
      expect(body.route_policy.enabled).toBe(false);
    });

    it('pre-fills enabled=false from policy', () => {
      renderModal(POLICY_WITHOUT_STATEMENTS);
      expect(screen.getByRole('checkbox', { name: /enabled/i })).not.toBeChecked();
    });
  });

  // ---------------------------------------------------------------------------
  // Pending-approval branch (IMP-87ec6f651f07)
  // ---------------------------------------------------------------------------

  describe('pending-approval branch', () => {
    it('shows the pending-approval notification and skips onSaved when the create is parked', async () => {
      mockPost.mockResolvedValueOnce({
        status: 202,
        data: {
          success: true,
          data: {
            pending: true,
            deferred_operation_id: 'dop-1',
            action_category: 'sdwan.route_policy_create',
            approval_request_id: 'ar-1',
            message: 'Approval required',
          },
        },
      });

      renderModal();

      fireEvent.change(screen.getByPlaceholderText(/prefer-internal-routes/i), {
        target: { value: 'my-new-policy' },
      });
      fireEvent.click(screen.getByRole('button', { name: /create policy/i }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({
            type: 'info',
            message: expect.stringMatching(/approval required/i),
            link: expect.objectContaining({ to: `${APPROVALS_SURFACE_PATH}?request=ar-1` }),
          }),
        ),
      );
      expect(mockOnSaved).not.toHaveBeenCalled();
      expect(mockOnClose).toHaveBeenCalled();
    });
  });
  // ---------------------------------------------------------------------------
  // Compile preview (IMP-d1900addb504)
  //
  // sdwanApi.compileRoutePolicy backed GET route_policies/:id/compile?peer_id
  // and had no caller, so an operator could not see what a policy compiles to
  // before applying it. The preview is per-peer, so it needs a peer selector,
  // and it only exists when editing an existing policy.
  // ---------------------------------------------------------------------------

  describe('compile preview', () => {
    const NETWORKS = [
      { id: 'net-1', name: 'core', status: 'active', cidr: 'fd00::/64' },
    ];
    const PEERS = [
      {
        id: 'peer-1',
        network_id: 'net-1',
        node_instance_id: 'inst-abcdef12',
        assigned_address: 'fd00::1/128',
        publicly_reachable: true,
        listen_port: 51820,
        status: 'active',
      },
      {
        id: 'peer-2',
        network_id: 'net-1',
        node_instance_id: 'inst-99887766',
        assigned_address: 'fd00::2/128',
        publicly_reachable: false,
        listen_port: 51820,
        status: 'active',
      },
    ];
    const COMPILED = {
      prefix_lists: ['ip prefix-list pl-internal permit 10.0.0.0/8 le 32'],
      ipv6_prefix_lists: [],
      as_path_lists: [],
      community_lists: [],
      route_maps: ['route-map prefer-internal-import permit 10'],
    };

    it('is not offered when creating a policy (no id to compile)', async () => {
      renderModal(null);
      expect(screen.queryByRole('button', { name: /show preview/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('button', { name: /preview compiled/i })).not.toBeInTheDocument();
    });

    it('fetches nothing until the operator opens the preview', () => {
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.getByRole('button', { name: /show preview/i })).toBeInTheDocument();
      expect(mockGet).not.toHaveBeenCalled();
    });

    it('compiles for the selected peer and renders the FRR output', async () => {
      mockGet.mockImplementation((url: string) => {
        if (url.startsWith('/system/sdwan/networks?') || url === '/system/sdwan/networks') {
          return Promise.resolve(
            envelope({ networks: NETWORKS, meta: { total: 1, page: 1, per_page: 25 } })
          );
        }
        if (url === '/system/sdwan/networks/net-1/peers') {
          return Promise.resolve(envelope({ peers: PEERS, count: PEERS.length }));
        }
        if (url.startsWith('/system/sdwan/route_policies/policy-1/compile')) {
          return Promise.resolve(envelope({ compiled: COMPILED }));
        }
        return Promise.reject(new Error(`unexpected GET ${url}`));
      });

      renderModal(POLICY_WITH_STATEMENTS);

      fireEvent.click(screen.getByRole('button', { name: /show preview/i }));

      await waitFor(() =>
        expect(screen.getByRole('button', { name: /preview compiled/i })).toBeInTheDocument()
      );

      // Network then peer — compile is per-peer and peers are network-scoped.
      await waitFor(() =>
        expect(screen.getByRole('option', { name: 'core' })).toBeInTheDocument()
      );
      fireEvent.change(screen.getByLabelText(/compile for network/i), {
        target: { value: 'net-1' },
      });
      await waitFor(() =>
        expect(screen.getByRole('option', { name: /inst-abc \(hub\)/i })).toBeInTheDocument()
      );
      fireEvent.change(screen.getByLabelText(/compile for peer/i), {
        target: { value: 'peer-1' },
      });

      fireEvent.click(screen.getByRole('button', { name: /preview compiled/i }));

      await waitFor(() =>
        expect(mockGet).toHaveBeenCalledWith(
          '/system/sdwan/route_policies/policy-1/compile?peer_id=peer-1'
        )
      );
      await waitFor(() =>
        expect(
          screen.getByText('route-map prefer-internal-import permit 10')
        ).toBeInTheDocument()
      );
    });
    it('drops the previous peer\'s output when the peer selection changes', async () => {
      mockGet.mockImplementation((url: string) => {
        if (url === '/system/sdwan/networks') {
          return Promise.resolve(
            envelope({ networks: NETWORKS, meta: { total: 1, page: 1, per_page: 25 } })
          );
        }
        if (url === '/system/sdwan/networks/net-1/peers') {
          return Promise.resolve(envelope({ peers: PEERS, count: PEERS.length }));
        }
        if (url.startsWith('/system/sdwan/route_policies/policy-1/compile')) {
          return Promise.resolve(envelope({ compiled: COMPILED }));
        }
        return Promise.reject(new Error(`unexpected GET ${url}`));
      });

      renderModal(POLICY_WITH_STATEMENTS);
      fireEvent.click(screen.getByRole('button', { name: /show preview/i }));

      // Wait for the loaded OPTION: the select renders immediately with only
      // its placeholder, and a change to a value it does not yet offer is a
      // silent no-op in jsdom.
      await waitFor(() =>
        expect(screen.getByRole('option', { name: 'core' })).toBeInTheDocument()
      );
      fireEvent.change(screen.getByLabelText(/compile for network/i), { target: { value: 'net-1' } });
      await waitFor(() =>
        expect(screen.getByRole('option', { name: /inst-abc \(hub\)/i })).toBeInTheDocument()
      );
      fireEvent.change(screen.getByLabelText(/compile for peer/i), { target: { value: 'peer-1' } });
      fireEvent.click(screen.getByRole('button', { name: /preview compiled/i }));

      await waitFor(() =>
        expect(screen.getByText('route-map prefer-internal-import permit 10')).toBeInTheDocument()
      );

      // Peer A's config must not sit on screen under peer B's name.
      fireEvent.change(screen.getByLabelText(/compile for peer/i), { target: { value: 'peer-2' } });
      await waitFor(() =>
        expect(
          screen.queryByText('route-map prefer-internal-import permit 10')
        ).not.toBeInTheDocument()
      );
    });

    it('is not offered without the three read permissions the preview needs', () => {
      mockHasPermission.mockImplementation(
        (perm: string) => perm !== 'system.sdwan.peers.read',
      );
      renderModal(POLICY_WITH_STATEMENTS);
      expect(screen.queryByRole('button', { name: /show preview/i })).not.toBeInTheDocument();
    });
  });
});
