import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { CiWebhooksTab } from './CiWebhooksTab';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// Permission predicate — prefixed "mock" so babel allows it in jest.mock factory.
// Individual tests can reassign this to restrict permissions.
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

const WEBHOOK_A = {
  id: 'wh-001',
  account_id: 'acct-1',
  label: 'main-ci',
  status: 'active' as const,
  secret_preview: 'abcd1234',
  last_received_at: '2026-05-01T12:00:00Z',
  received_count: 42,
  last_rotated_at: '2026-04-01T08:00:00Z',
  webhook_url_path: '/api/v1/system/disk_image_webhooks/wh-001/receive',
  created_at: '2026-03-01T00:00:00Z',
  updated_at: '2026-05-01T12:00:00Z',
};

const WEBHOOK_B = {
  id: 'wh-002',
  account_id: 'acct-1',
  label: 'release-pipeline',
  status: 'active' as const,
  secret_preview: 'xyz98765',
  last_received_at: undefined,
  received_count: 0,
  last_rotated_at: undefined,
  webhook_url_path: '/api/v1/system/disk_image_webhooks/wh-002/receive',
  created_at: '2026-04-01T00:00:00Z',
  updated_at: '2026-04-01T00:00:00Z',
};

const CREATED_RESPONSE = {
  disk_image_webhook: WEBHOOK_A,
  secret_plaintext: 'super-secret-value-shown-once',
  webhook_url: 'https://powernode.example.com/api/v1/system/disk_image_webhooks/wh-001/receive',
  note: 'Store this secret in your CI secret manager immediately.',
};

/**
 * Wrap an API payload in the double-envelope that AxiosResponse + backend produce.
 * The component calls diskImageWebhooksApi which calls extractData(response) on the
 * raw AxiosResponse, so the mock resolves to { data: { success: true, data: <payload> } }.
 */
function envelope<T>(data: T) {
  return { data: { success: true, data } };
}

function listEnvelope(webhooks: typeof WEBHOOK_A[]) {
  return envelope({ disk_image_webhooks: webhooks });
}

// =============================================================================
// Render helper
// =============================================================================

const renderTab = (props: React.ComponentProps<typeof CiWebhooksTab> = {}) =>
  render(
    <BrowserRouter>
      <CiWebhooksTab {...props} />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('CiWebhooksTab', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockPut.mockReset();
    mockDelete.mockReset();
    mockAddNotification.mockReset();
    mockPermissionGranted = (_perm: string) => true;
    jest.spyOn(window, 'confirm').mockReturnValue(true);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Initial load — loading state
  // ---------------------------------------------------------------------------

  it('shows loading indicator while fetching', () => {
    // Never resolves during this test
    mockGet.mockReturnValue(new Promise(() => {}));

    renderTab();

    expect(screen.getByText('Loading…')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  it('shows empty-state message when no webhooks exist', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));

    renderTab();

    await waitFor(() =>
      expect(
        screen.getByText(/No webhooks yet/i),
      ).toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // List rendering
  // ---------------------------------------------------------------------------

  it('renders fetched webhooks and calls the correct API endpoint', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A, WEBHOOK_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());
    expect(screen.getByText('release-pipeline')).toBeInTheDocument();

    // Badge counts
    expect(screen.getByText('2')).toBeInTheDocument();

    // Verify exact URL called
    expect(mockGet).toHaveBeenCalledWith('/system/disk_image_webhooks');
  });

  it('shows secret preview in the row summary', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());
    expect(screen.getByText(/abcd1234/)).toBeInTheDocument();
  });

  it('shows received count in the row summary', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());
    expect(screen.getByText(/Received 42 times/)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Row expand / collapse
  // ---------------------------------------------------------------------------

  it('expands a row to show detail fields when expand button clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    // Detail fields are NOT visible yet
    expect(screen.queryByText('Webhook URL path')).not.toBeInTheDocument();

    // Click expand button (title="Expand details")
    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Webhook URL path')).toBeInTheDocument(),
    );

    // Should show the webhook URL path value
    expect(
      screen.getByText('/api/v1/system/disk_image_webhooks/wh-001/receive'),
    ).toBeInTheDocument();

    // The button title should now be "Collapse details"
    expect(screen.getByTitle('Collapse details')).toBeInTheDocument();
  });

  it('shows "Never" for last_received when missing in expanded row', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_B]));

    renderTab();

    await waitFor(() => expect(screen.getByText('release-pipeline')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Expand details'));

    await waitFor(() =>
      expect(screen.getByText('Webhook URL path')).toBeInTheDocument(),
    );

    expect(screen.getAllByText('Never').length).toBeGreaterThan(0);
  });

  it('collapses a previously-expanded row when the chevron is clicked again', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    // Expand
    fireEvent.click(screen.getByTitle('Expand details'));
    await waitFor(() => expect(screen.getByText('Webhook URL path')).toBeInTheDocument());

    // Collapse
    fireEvent.click(screen.getByTitle('Collapse details'));
    await waitFor(() =>
      expect(screen.queryByText('Webhook URL path')).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Revoke (delete) flow
  // ---------------------------------------------------------------------------

  it('calls destroy endpoint and refreshes list after confirming revoke', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]))
      .mockResolvedValueOnce(listEnvelope([]));
    mockDelete.mockResolvedValue({ data: { success: true } });

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Revoke webhook'));

    await waitFor(() =>
      expect(mockDelete).toHaveBeenCalledWith('/system/disk_image_webhooks/wh-001'),
    );

    // confirm was called with the appropriate message
    expect(window.confirm).toHaveBeenCalledWith(
      expect.stringContaining('main-ci'),
    );

    // Success notification
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: expect.stringContaining('main-ci') }),
      ),
    );
  });

  it('does not call destroy if the user cancels the confirm dialog', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(false);

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Revoke webhook'));

    await waitFor(() => expect(window.confirm).toHaveBeenCalled());
    expect(mockDelete).not.toHaveBeenCalled();
  });

  it('shows error notification when revoke fails', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));
    mockDelete.mockRejectedValue(new Error('Network error'));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Revoke webhook'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Network error' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // Rotate secret flow
  // ---------------------------------------------------------------------------

  it('calls rotate_secret endpoint and shows SecretShownOnceModal on success', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]))
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]));
    mockPost.mockResolvedValue(envelope(CREATED_RESPONSE));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate secret'));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/disk_image_webhooks/wh-001/rotate_secret',
        {},
      ),
    );

    // SecretShownOnceModal should appear
    await waitFor(() =>
      expect(
        screen.getByText(/This secret is shown ONCE/i),
      ).toBeInTheDocument(),
    );

    // The plaintext secret is displayed
    expect(screen.getByText('super-secret-value-shown-once')).toBeInTheDocument();
  });

  it('shows error notification when rotate fails', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));
    mockPost.mockRejectedValue(new Error('Rotate error'));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate secret'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Rotate error' }),
      ),
    );
  });

  it('does not call rotate_secret if the user cancels the confirm dialog', async () => {
    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));
    jest.spyOn(window, 'confirm').mockReturnValue(false);

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate secret'));

    await waitFor(() => expect(window.confirm).toHaveBeenCalled());
    expect(mockPost).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Permission gating
  // ---------------------------------------------------------------------------

  it('hides rotate button when user lacks rotate_secret permission', async () => {
    mockPermissionGranted = (perm: string) => perm !== 'system.disk_image_webhooks.rotate_secret';

    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    expect(screen.queryByTitle('Rotate secret')).not.toBeInTheDocument();
    // Revoke button should still be visible
    expect(screen.getByTitle('Revoke webhook')).toBeInTheDocument();
  });

  it('hides revoke button when user lacks delete permission', async () => {
    mockPermissionGranted = (perm: string) => perm !== 'system.disk_image_webhooks.delete';

    mockGet.mockResolvedValue(listEnvelope([WEBHOOK_A]));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    expect(screen.queryByTitle('Revoke webhook')).not.toBeInTheDocument();
    expect(screen.getByTitle('Rotate secret')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Create modal — onActionsReady callback
  // ---------------------------------------------------------------------------

  it('calls onActionsReady with an openCreate handle on mount', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    const onActionsReady = jest.fn();

    renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    const handle = onActionsReady.mock.calls[0][0];
    expect(handle).toHaveProperty('openCreate');
    expect(typeof handle.openCreate).toBe('function');
  });

  it('calls onActionsReady(null) on unmount', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    const onActionsReady = jest.fn();

    const { unmount } = renderTab({ onActionsReady });

    await waitFor(() => expect(onActionsReady).toHaveBeenCalled());

    unmount();

    expect(onActionsReady).toHaveBeenLastCalledWith(null);
  });

  // ---------------------------------------------------------------------------
  // Create webhook modal
  // ---------------------------------------------------------------------------

  it('opens the create modal when openCreate handle is called', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    let handle: { openCreate: () => void } | null = null;

    renderTab({
      onActionsReady: (h) => { handle = h; },
    });

    await waitFor(() => expect(handle).not.toBeNull());

    fireEvent.click(screen.getByText(/No webhooks yet/i)); // just to ensure mount
    handle!.openCreate();

    await waitFor(() =>
      expect(screen.getByText('New disk-image webhook')).toBeInTheDocument(),
    );
  });

  it('submits create form with label and shows secret modal on success', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([]))
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]));
    mockPost.mockResolvedValue(envelope(CREATED_RESPONSE));

    let handle: { openCreate: () => void } | null = null;

    renderTab({
      onActionsReady: (h) => { handle = h; },
    });

    await waitFor(() => expect(handle).not.toBeNull());
    handle!.openCreate();

    await waitFor(() =>
      expect(screen.getByText('New disk-image webhook')).toBeInTheDocument(),
    );

    // Type a label
    fireEvent.change(screen.getByLabelText(/label/i), {
      target: { value: 'main-ci' },
    });

    // Click Create webhook button
    fireEvent.click(screen.getByRole('button', { name: 'Create webhook' }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith(
        '/system/disk_image_webhooks',
        { label: 'main-ci' },
      ),
    );

    // The SecretShownOnceModal should appear with the webhook label in title
    await waitFor(() =>
      expect(screen.getByText(/Webhook: main-ci/i)).toBeInTheDocument(),
    );

    // Plaintext secret is displayed
    expect(screen.getByText('super-secret-value-shown-once')).toBeInTheDocument();

    // Webhook URL is displayed
    expect(
      screen.getByText(
        'https://powernode.example.com/api/v1/system/disk_image_webhooks/wh-001/receive',
      ),
    ).toBeInTheDocument();

    // Note is displayed
    expect(
      screen.getByText('Store this secret in your CI secret manager immediately.'),
    ).toBeInTheDocument();
  });

  it('disables Create webhook button when label is empty', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    let handle: { openCreate: () => void } | null = null;

    renderTab({ onActionsReady: (h) => { handle = h; } });

    await waitFor(() => expect(handle).not.toBeNull());
    handle!.openCreate();

    await waitFor(() =>
      expect(screen.getByText('New disk-image webhook')).toBeInTheDocument(),
    );

    const createBtn = screen.getByRole('button', { name: 'Create webhook' });
    expect(createBtn).toBeDisabled();
  });

  it('closes create modal when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    let handle: { openCreate: () => void } | null = null;

    renderTab({ onActionsReady: (h) => { handle = h; } });

    await waitFor(() => expect(handle).not.toBeNull());
    handle!.openCreate();

    await waitFor(() =>
      expect(screen.getByText('New disk-image webhook')).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    await waitFor(() =>
      expect(screen.queryByText('New disk-image webhook')).not.toBeInTheDocument(),
    );
  });

  it('shows error notification when create fails', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    mockPost.mockRejectedValue(new Error('Create failed'));
    let handle: { openCreate: () => void } | null = null;

    renderTab({ onActionsReady: (h) => { handle = h; } });

    await waitFor(() => expect(handle).not.toBeNull());
    handle!.openCreate();

    await waitFor(() =>
      expect(screen.getByText('New disk-image webhook')).toBeInTheDocument(),
    );

    fireEvent.change(screen.getByLabelText(/label/i), {
      target: { value: 'my-pipeline' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Create webhook' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Create failed' }),
      ),
    );
  });

  // ---------------------------------------------------------------------------
  // SecretShownOnceModal — acknowledge gate
  // ---------------------------------------------------------------------------

  it('requires acknowledge checkbox before Done can be clicked', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]))
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]));
    mockPost.mockResolvedValue(envelope(CREATED_RESPONSE));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate secret'));

    await waitFor(() =>
      expect(screen.getByText(/This secret is shown ONCE/i)).toBeInTheDocument(),
    );

    const doneBtn = screen.getByRole('button', { name: 'Done' });
    expect(doneBtn).toBeDisabled();

    // Check the acknowledge checkbox
    fireEvent.click(
      screen.getByLabelText(/I have saved the secret/i),
    );

    await waitFor(() => expect(doneBtn).not.toBeDisabled());
  });

  it('closes SecretShownOnceModal when Done is clicked after acknowledging', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]))
      .mockResolvedValueOnce(listEnvelope([WEBHOOK_A]));
    mockPost.mockResolvedValue(envelope(CREATED_RESPONSE));

    renderTab();

    await waitFor(() => expect(screen.getByText('main-ci')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Rotate secret'));

    await waitFor(() =>
      expect(screen.getByText(/This secret is shown ONCE/i)).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByLabelText(/I have saved the secret/i));

    const doneBtn = screen.getByRole('button', { name: 'Done' });
    await waitFor(() => expect(doneBtn).not.toBeDisabled());
    fireEvent.click(doneBtn);

    await waitFor(() =>
      expect(screen.queryByText(/This secret is shown ONCE/i)).not.toBeInTheDocument(),
    );
  });

  // ---------------------------------------------------------------------------
  // Load error
  // ---------------------------------------------------------------------------

  it('shows error notification when list fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('Server down'));

    renderTab();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Failed to load disk-image webhooks',
        }),
      ),
    );
  });
});
