import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { CreateHostBridgeModal } from './CreateHostBridgeModal';

// =============================================================================
// Mocks
// =============================================================================

const mockPost = jest.fn();
const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const mockGetNodes = jest.fn();
const mockGetNodeInstances = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getNodes: (...args: unknown[]) => mockGetNodes(...args),
    getNodeInstances: (...args: unknown[]) => mockGetNodeInstances(...args),
  },
}));

// =============================================================================
// Helpers & fixtures
// =============================================================================

function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

/**
 * What axios ACTUALLY rejects with. `.message` is the generic status line; the
 * server's sentence sits in response.data.error. A spec that rejects with a
 * bare Error validates the wrong shape and passes whether or not the component
 * reads the body.
 */
function axiosError(serverMessage: string, status = 422) {
  return Object.assign(new Error(`Request failed with status code ${status}`), {
    response: { status, data: { error: serverMessage } },
  });
}

const NODE = { id: 'node-1', name: 'dna' };
const INSTANCE_A = { id: 'ni-abc', name: 'node-alpha', status: 'running' };
const INSTANCE_B = { id: 'ni-def', name: 'node-beta', status: 'running' };

const BRIDGE_CREATED = {
  id: 'hb-new',
  node_instance_id: 'ni-abc',
  node_instance_name: 'node-alpha',
  network_profile: 'heavyweight',
  short_id: 7,
  bridge_name: 'ovs-br-007',
  kind: 'ovs',
  state: 'pending',
};

const renderModal = (props: Partial<React.ComponentProps<typeof CreateHostBridgeModal>> = {}) =>
  render(
    <CreateHostBridgeModal
      isOpen
      onClose={props.onClose ?? jest.fn()}
      onCreated={props.onCreated ?? jest.fn()}
    />,
  );

/** Load the host list and pick INSTANCE_A. */
async function pickHost(id = 'ni-abc') {
  await waitFor(() => expect(screen.getByRole('option', { name: /node-alpha/ })).toBeInTheDocument());
  fireEvent.change(screen.getByLabelText('Host'), { target: { value: id } });
}

// =============================================================================
// Tests
// =============================================================================

describe('CreateHostBridgeModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
    mockPost.mockReset();
    mockAddNotification.mockReset();
    mockGetNodes.mockReset();
    mockGetNodeInstances.mockReset();
    mockGetNodes.mockResolvedValue({ nodes: [NODE] });
    mockGetNodeInstances.mockResolvedValue({ node_instances: [INSTANCE_A, INSTANCE_B] });
  });

  it('renders nothing while closed and loads no hosts', () => {
    render(<CreateHostBridgeModal isOpen={false} onClose={jest.fn()} onCreated={jest.fn()} />);

    expect(screen.queryByText('Allocate host bridge')).not.toBeInTheDocument();
    expect(mockGetNodes).not.toHaveBeenCalled();
  });

  it('lists every node instance across all nodes as a host option', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('option', { name: /node-alpha/ })).toBeInTheDocument());
    expect(screen.getByRole('option', { name: /node-beta/ })).toBeInTheDocument();
  });

  it('notifies when the host list fails to load', async () => {
    mockGetNodes.mockRejectedValue(new Error('nope'));

    renderModal();

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to load node instances',
      }),
    );
  });

  it('keeps Allocate disabled until a host is chosen', async () => {
    renderModal();

    await waitFor(() => expect(screen.getByRole('option', { name: /node-alpha/ })).toBeInTheDocument());
    expect(screen.getByRole('button', { name: 'Allocate' })).toBeDisabled();

    await pickHost();

    expect(screen.getByRole('button', { name: 'Allocate' })).not.toBeDisabled();
  });

  it('omits kind entirely when the operator leaves it to the allocator', async () => {
    // The allocator resolves kind from the host's network_profile. Sending a
    // client-side default would be a second surface answering the same payload.
    mockPost.mockResolvedValue(envelope({ host_bridge: BRIDGE_CREATED }));
    renderModal();

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() => expect(mockPost).toHaveBeenCalled());
    // toHaveBeenCalledWith uses toEqual semantics, which ignore an explicit
    // `kind: undefined` — so the KEY has to be absent, not just falsy.
    expect(mockPost).toHaveBeenCalledWith('/system/sdwan/host_bridges', {
      node_instance_id: 'ni-abc',
    });
    expect(Object.keys(mockPost.mock.calls[0][1] as object)).toEqual(['node_instance_id']);
  });

  it('requests one page of nodes and warns when hosts are being truncated', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE], meta: { total_pages: 3, total_count: 120 } });

    renderModal();

    await waitFor(() => expect(screen.getByRole('option', { name: /node-alpha/ })).toBeInTheDocument());
    expect(mockGetNodes).toHaveBeenCalledWith({ per_page: 50 });
    expect(screen.getByText(/first 50 nodes only/i)).toBeInTheDocument();
  });

  it('does not warn when every node fits on one page', async () => {
    mockGetNodes.mockResolvedValue({ nodes: [NODE], meta: { total_pages: 1, total_count: 1 } });

    renderModal();

    await waitFor(() => expect(screen.getByRole('option', { name: /node-alpha/ })).toBeInTheDocument());
    expect(screen.queryByText(/first 50 nodes only/i)).not.toBeInTheDocument();
  });

  it('sends kind when the operator overrides it', async () => {
    mockPost.mockResolvedValue(envelope({ host_bridge: { ...BRIDGE_CREATED, kind: 'linux' } }));
    renderModal();

    await pickHost();
    fireEvent.change(screen.getByLabelText(/kind/i), { target: { value: 'linux' } });
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() =>
      expect(mockPost).toHaveBeenCalledWith('/system/sdwan/host_bridges', {
        node_instance_id: 'ni-abc',
        kind: 'linux',
      }),
    );
  });

  it('reports success naming the allocated bridge and tells the operator to activate it', async () => {
    mockPost.mockResolvedValue(envelope({ host_bridge: BRIDGE_CREATED }));
    const onCreated = jest.fn();
    renderModal({ onCreated });

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: expect.stringContaining('ovs-br-007'),
      }),
    );
    expect(mockAddNotification).toHaveBeenCalledWith({
      type: 'success',
      message: expect.stringMatching(/activate/i),
    });
    expect(onCreated).toHaveBeenCalled();
  });

  it('names the state the server returned rather than assuming pending', async () => {
    // Allocation is idempotent and readopting: an existing bridge comes back
    // unchanged, and a previously released one is revived straight to ACTIVE.
    // Telling the operator to "activate it" there is the inverse of the truth.
    mockPost.mockResolvedValue(
      envelope({ host_bridge: { ...BRIDGE_CREATED, state: 'active' } }),
    );
    renderModal();

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'success',
        message: expect.stringContaining('active'),
      }),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith({
      type: 'success',
      message: expect.stringMatching(/activate it/i),
    });
  });

  it('reports the pending-approval branch rather than naming a bridge that does not exist', async () => {
    mockPost.mockResolvedValue(
      envelope({
        pending: true,
        deferred_operation_id: 'defop-3',
        action_category: 'sdwan.host_bridge_create',
        approval_request_id: 'appr-3',
        message: 'parked',
      }),
    );
    const onCreated = jest.fn();
    const onClose = jest.fn();
    renderModal({ onCreated, onClose });

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'info',
          message: expect.stringMatching(/approval required/i),
          link: expect.objectContaining({ to: '/app/ai/agents/autonomy' }),
        }),
      ),
    );
    expect(mockAddNotification).not.toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
    // The dialog closes, but nothing was written — gate! never runs on_proceed
    // on :pending — so the parent must not be told to refetch as if it had.
    expect(onClose).toHaveBeenCalled();
    expect(onCreated).not.toHaveBeenCalled();
  });

  it('surfaces the server sentence on failure and leaves the form open to retry', async () => {
    mockPost.mockRejectedValue(axiosError('kind must be one of linux, ovs'));
    const onCreated = jest.fn();
    renderModal({ onCreated });

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'kind must be one of linux, ovs',
      }),
    );
    expect(onCreated).not.toHaveBeenCalled();
    await waitFor(() => expect(screen.getByRole('button', { name: 'Allocate' })).not.toBeDisabled());
  });

  it('clears the chosen host when the operator cancels', async () => {
    const onClose = jest.fn();
    const { rerender } = renderModal({ onClose });

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(onClose).toHaveBeenCalled();
    // Cancel sits inside the <form>. Without an explicit type="button" it
    // defaults to submit and would fire the allocation on the way out.
    expect(mockPost).not.toHaveBeenCalled();

    rerender(<CreateHostBridgeModal isOpen onClose={onClose} onCreated={jest.fn()} />);
    await waitFor(() => expect(screen.getByRole('option', { name: /node-alpha/ })).toBeInTheDocument());
    expect(screen.getByLabelText('Host')).toHaveValue('');
  });

  it('does not submit twice while a request is in flight', async () => {
    let resolvePost!: (v: unknown) => void;
    mockPost.mockReturnValue(new Promise((res) => { resolvePost = res; }));
    renderModal();

    await pickHost();
    fireEvent.click(screen.getByRole('button', { name: 'Allocate' }));

    await waitFor(() => expect(screen.getByRole('button', { name: 'Allocating…' })).toBeDisabled());
    fireEvent.click(screen.getByRole('button', { name: 'Allocating…' }));

    expect(mockPost).toHaveBeenCalledTimes(1);
    resolvePost(envelope({ host_bridge: BRIDGE_CREATED }));
  });
});
