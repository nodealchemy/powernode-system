import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { ScalingPanel } from './ScalingPanel';

// =============================================================================
// Mocks
//
// ScalingPanel imports platformDeploymentsApi (which wraps apiClient.get +
// apiClient.patch) and useNotifications. We mock at the API facade level so
// that tests control exactly what the component sees from the API layer.
// =============================================================================

const mockGet = jest.fn();
const mockPatch = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    patch: (...args: unknown[]) => mockPatch(...args),
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

import type { DeploymentSummary } from '../../types/deployment.types';

const DEPLOY_API: DeploymentSummary = {
  id: 'dep-api-1',
  name: 'powernode-hub-api',
  service_role: 'api',
  target_replicas: 2,
  actual_replicas: 2,
  actual_by_status: { running: 2 },
  public_dns_hostname: null,
  satellite_extension_slug: null,
  node_template: { id: 'tpl-1', name: 'Hub API Template', slug: 'hub-api' },
  virtual_ip: { id: 'vip-1', cidr: '10.0.0.1/32', preferred_endpoint: null },
  metadata: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const DEPLOY_WORKER: DeploymentSummary = {
  id: 'dep-worker-1',
  name: 'powernode-worker',
  service_role: 'worker',
  target_replicas: 1,
  actual_replicas: 3, // intentional drift (over-provisioned)
  actual_by_status: { running: 3 },
  public_dns_hostname: null,
  satellite_extension_slug: null,
  node_template: null,
  virtual_ip: null,
  metadata: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

const DEPLOY_ZERO_REPLICAS: DeploymentSummary = {
  id: 'dep-fe-1',
  name: 'powernode-frontend',
  service_role: 'frontend',
  target_replicas: 0,
  actual_replicas: 0,
  actual_by_status: {},
  public_dns_hostname: null,
  satellite_extension_slug: null,
  node_template: null,
  virtual_ip: null,
  metadata: {},
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

/**
 * Build an AxiosResponse-shaped mock for the list endpoint.
 * The double-envelope shape: { data: { success: true, data: <payload> } }.
 * `platformDeploymentsApi.list` calls extractData which reads response.data.data.
 */
function listEnvelope(deployments: DeploymentSummary[]) {
  return {
    data: {
      success: true,
      data: { deployments, count: deployments.length },
    },
  };
}

/**
 * Build an AxiosResponse-shaped mock for the update (PATCH) endpoint.
 * `platformDeploymentsApi.update` calls extractData → response.data.data.deployment
 */
function updateEnvelope(deployment: DeploymentSummary) {
  return {
    data: {
      success: true,
      data: { deployment },
    },
  };
}

// =============================================================================
// Helpers
// =============================================================================

const renderPanel = () => render(<ScalingPanel />);

// =============================================================================
// Tests
// =============================================================================

describe('ScalingPanel', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPatch.mockReset();
    mockAddNotification.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  it('shows loading spinner indicator in header while fetching', () => {
    // Never resolves during this test — holds the loading state
    mockGet.mockReturnValue(new Promise(() => {}));
    renderPanel();
    expect(screen.getByText('loading…')).toBeInTheDocument();
  });

  it('renders the Deployments header with component count after load', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API, DEPLOY_WORKER]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('2 components')).toBeInTheDocument());
    expect(screen.getByRole('heading', { name: 'Deployments' })).toBeInTheDocument();
  });

  it('shows singular "1 component" when exactly one deployment is returned', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('1 component')).toBeInTheDocument());
  });

  it('renders the empty state when no deployments exist', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText(/no platform deployments declared yet/i)).toBeInTheDocument(),
    );
  });

  it('shows an error banner when the API call fails', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('Network error')).toBeInTheDocument(),
    );
  });

  it('uses a generic error message for non-Error rejections', async () => {
    mockGet.mockRejectedValue('some string error');
    renderPanel();
    await waitFor(() =>
      expect(screen.getByText('Failed to load deployments')).toBeInTheDocument(),
    );
  });

  it('renders the list table with all deployments returned by the API', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API, DEPLOY_WORKER]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());
    expect(screen.getByText('powernode-worker')).toBeInTheDocument();
  });

  it('calls GET /system/platform/deployments on mount', async () => {
    mockGet.mockResolvedValue(listEnvelope([]));
    renderPanel();
    await waitFor(() => expect(mockGet).toHaveBeenCalledWith('/system/platform/deployments'));
  });

  // ---------------------------------------------------------------------------
  // Table cell rendering
  // ---------------------------------------------------------------------------

  it('renders the service_role badge for each row', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API, DEPLOY_WORKER]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());
    expect(screen.getByText('api')).toBeInTheDocument();
    expect(screen.getByText('worker')).toBeInTheDocument();
  });

  it('renders the node_template slug when available', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('hub-api')).toBeInTheDocument());
  });

  it('renders the node_template name when slug is null', async () => {
    const deploy = {
      ...DEPLOY_API,
      node_template: { id: 'tpl-2', name: 'Hub API Template', slug: null },
    };
    mockGet.mockResolvedValue(listEnvelope([deploy]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('Hub API Template')).toBeInTheDocument());
  });

  it('renders virtual_ip cidr when present', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('10.0.0.1/32')).toBeInTheDocument());
  });

  it('renders target_replicas and actual replicas counts', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());
    // target replicas = 2
    expect(screen.getByText('2')).toBeInTheDocument();
    // actual replicas = 2
    expect(screen.getByText('(2 live)')).toBeInTheDocument();
  });

  it('renders "(N live)" actual replica count for each deployment', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_WORKER]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-worker')).toBeInTheDocument());
    // DEPLOY_WORKER: actual_replicas = 3
    expect(screen.getByText('(3 live)')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Refresh button
  // ---------------------------------------------------------------------------

  it('re-fetches deployments when the Refresh button is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API, DEPLOY_WORKER]));

    renderPanel();
    await waitFor(() => expect(screen.getByText('1 component')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Refresh'));

    await waitFor(() => expect(screen.getByText('2 components')).toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------------------------------
  // Inline editing — entering edit mode
  // ---------------------------------------------------------------------------

  it('switches a row into edit mode when the Edit button is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    const editBtn = screen.getByTitle('Edit target_replicas');
    fireEvent.click(editBtn);

    // Input appears pre-populated with current target_replicas
    const input = screen.getByRole('spinbutton');
    expect(input).toBeInTheDocument();
    expect((input as HTMLInputElement).value).toBe('2');
  });

  it('shows Save and Cancel buttons when in edit mode', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));

    expect(screen.getByRole('button', { name: /save/i })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /cancel/i })).toBeInTheDocument();
  });

  it('returns to view mode when Cancel is clicked', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    expect(screen.getByRole('spinbutton')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument();
    expect(screen.getByTitle('Edit target_replicas')).toBeInTheDocument();
  });

  it('cancels edit mode when Escape key is pressed in the input', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    const input = screen.getByRole('spinbutton');

    fireEvent.keyDown(input, { key: 'Escape' });

    expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Inline editing — saving
  // ---------------------------------------------------------------------------

  it('PATCHes to /system/platform/deployments/:id with new target_replicas on Save', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    const updated = { ...DEPLOY_API, target_replicas: 5 };
    mockPatch.mockResolvedValue(updateEnvelope(updated));
    // fetchDeployments is re-called after save
    mockGet.mockResolvedValueOnce(listEnvelope([DEPLOY_API])).mockResolvedValueOnce(listEnvelope([updated]));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '5' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/platform/deployments/dep-api-1',
        { target_replicas: 5 },
      ),
    );
  });

  it('submits via Enter key in the input', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    const updated = { ...DEPLOY_API, target_replicas: 4 };
    mockPatch.mockResolvedValue(updateEnvelope(updated));
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([updated]));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    const input = screen.getByRole('spinbutton');
    fireEvent.change(input, { target: { value: '4' } });
    fireEvent.keyDown(input, { key: 'Enter' });

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/platform/deployments/dep-api-1',
        { target_replicas: 4 },
      ),
    );
  });

  it('shows a success notification with singular "replica" after save', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    const updated = { ...DEPLOY_API, target_replicas: 1 };
    mockPatch.mockResolvedValue(updateEnvelope(updated));
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([updated]));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '1' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'powernode-hub-api target set to 1 replica.',
      }),
    );
  });

  it('shows a success notification with plural "replicas" when target > 1', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    const updated = { ...DEPLOY_API, target_replicas: 5 };
    mockPatch.mockResolvedValue(updateEnvelope(updated));
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([updated]));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '5' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'powernode-hub-api target set to 5 replicas.',
      }),
    );
  });

  it('closes edit mode and re-fetches after a successful save', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([{ ...DEPLOY_API, target_replicas: 3 }]));
    mockPatch.mockResolvedValue(updateEnvelope({ ...DEPLOY_API, target_replicas: 3 }));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '3' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() => expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument());
    expect(mockGet).toHaveBeenCalledTimes(2);
  });

  it('does NOT call PATCH when Save is clicked with the same value as current target', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    // value already pre-populated to '2' — click Save without changing
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    // Should cancel silently — no PATCH, back to view mode
    await waitFor(() => expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument());
    expect(mockPatch).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('shows an error and does not PATCH when target_replicas is negative', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '-1' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(
        screen.getByText('target_replicas must be a non-negative integer'),
      ).toBeInTheDocument(),
    );
    expect(mockPatch).not.toHaveBeenCalled();
  });

  it('shows an error and does not PATCH when the input is not a number', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: 'abc' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(
        screen.getByText('target_replicas must be a non-negative integer'),
      ).toBeInTheDocument(),
    );
    expect(mockPatch).not.toHaveBeenCalled();
  });

  it('allows 0 as a valid target_replicas value', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    const updated = { ...DEPLOY_API, target_replicas: 0 };
    mockPatch.mockResolvedValue(updateEnvelope(updated));
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([updated]));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '0' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/platform/deployments/dep-api-1',
        { target_replicas: 0 },
      ),
    );
  });

  it('dismisses the error banner when the X button on the error is clicked', async () => {
    mockGet.mockRejectedValue(new Error('Network error'));
    renderPanel();
    await waitFor(() => expect(screen.getByText('Network error')).toBeInTheDocument());

    // The error banner has an X dismiss button
    const banner = screen.getByText('Network error').closest('div')!;
    const xBtn = within(banner).getByRole('button');
    fireEvent.click(xBtn);

    await waitFor(() => expect(screen.queryByText('Network error')).not.toBeInTheDocument());
  });

  // ---------------------------------------------------------------------------
  // Save error path
  // ---------------------------------------------------------------------------

  it('shows an error notification when PATCH fails', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    mockPatch.mockRejectedValue(new Error('Server error 500'));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '5' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Server error 500',
      }),
    );
  });

  it('shows generic "Update failed" notification for non-Error PATCH rejections', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    mockPatch.mockRejectedValue('oops');

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Edit target_replicas'));
    fireEvent.change(screen.getByRole('spinbutton'), { target: { value: '5' } });
    fireEvent.click(screen.getByRole('button', { name: /save/i }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Update failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Nudge buttons (increment / decrement)
  // ---------------------------------------------------------------------------

  it('renders Increment target and Decrement target nudge buttons in view mode', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    expect(screen.getByTitle('Increment target')).toBeInTheDocument();
    expect(screen.getByTitle('Decrement target')).toBeInTheDocument();
  });

  it('PATCHes with target_replicas + 1 when Increment is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([{ ...DEPLOY_API, target_replicas: 3 }]));
    mockPatch.mockResolvedValue(updateEnvelope({ ...DEPLOY_API, target_replicas: 3 }));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Increment target'));

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/platform/deployments/dep-api-1',
        { target_replicas: 3 },
      ),
    );
  });

  it('PATCHes with target_replicas - 1 when Decrement is clicked', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([{ ...DEPLOY_API, target_replicas: 1 }]));
    mockPatch.mockResolvedValue(updateEnvelope({ ...DEPLOY_API, target_replicas: 1 }));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Decrement target'));

    await waitFor(() =>
      expect(mockPatch).toHaveBeenCalledWith(
        '/system/platform/deployments/dep-api-1',
        { target_replicas: 1 },
      ),
    );
  });

  it('disables Decrement button when target_replicas is already 0', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_ZERO_REPLICAS]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-frontend')).toBeInTheDocument());

    const decrementBtn = screen.getByTitle('Decrement target');
    expect(decrementBtn).toBeDisabled();
  });

  it('does NOT call PATCH when Decrement is clicked but target is already 0', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_ZERO_REPLICAS]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-frontend')).toBeInTheDocument());

    // Button is disabled, but also the nudge handler checks next === target
    const decrementBtn = screen.getByTitle('Decrement target') as HTMLButtonElement;
    expect(decrementBtn.disabled).toBe(true);
    expect(mockPatch).not.toHaveBeenCalled();
  });

  it('shows success notification with plural "replicas" after nudge increment', async () => {
    mockGet
      .mockResolvedValueOnce(listEnvelope([DEPLOY_API]))
      .mockResolvedValueOnce(listEnvelope([{ ...DEPLOY_API, target_replicas: 3 }]));
    mockPatch.mockResolvedValue(updateEnvelope({ ...DEPLOY_API, target_replicas: 3 }));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Increment target'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: 'powernode-hub-api target set to 3 replicas.',
      }),
    );
  });

  it('shows error notification when nudge PATCH fails', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API]));
    mockPatch.mockRejectedValue(new Error('Nudge failed'));

    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    fireEvent.click(screen.getByTitle('Increment target'));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Nudge failed',
      }),
    );
  });

  // ---------------------------------------------------------------------------
  // Multiple rows — only one row edits at a time
  // ---------------------------------------------------------------------------

  it('only one row enters edit mode at a time', async () => {
    mockGet.mockResolvedValue(listEnvelope([DEPLOY_API, DEPLOY_WORKER]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('powernode-hub-api')).toBeInTheDocument());

    // Two edit buttons, click the first
    const editBtns = screen.getAllByTitle('Edit target_replicas');
    expect(editBtns).toHaveLength(2);
    fireEvent.click(editBtns[0]);

    // Only one input visible
    expect(screen.getAllByRole('spinbutton')).toHaveLength(1);
  });

  // ---------------------------------------------------------------------------
  // RoleBadge rendering
  // ---------------------------------------------------------------------------

  it('renders "reverse-proxy" role label correctly', async () => {
    const deploy: DeploymentSummary = {
      ...DEPLOY_API,
      id: 'dep-rp',
      name: 'powernode-reverse-proxy',
      service_role: 'reverse-proxy',
    };
    mockGet.mockResolvedValue(listEnvelope([deploy]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('reverse-proxy')).toBeInTheDocument());
  });

  it('renders "satellite" label for satellite-runtime role', async () => {
    const deploy: DeploymentSummary = {
      ...DEPLOY_API,
      id: 'dep-sat',
      name: 'powernode-satellite',
      service_role: 'satellite-runtime',
    };
    mockGet.mockResolvedValue(listEnvelope([deploy]));
    renderPanel();
    await waitFor(() => expect(screen.getByText('satellite')).toBeInTheDocument());
  });
});
