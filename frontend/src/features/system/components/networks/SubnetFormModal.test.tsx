import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { SubnetFormModal } from './SubnetFormModal';
import type { SystemProviderNetworkSubnet } from '@system/features/system/types/system.types';

const mockCreate = jest.fn();
const mockUpdate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createNetworkSubnet: (...args: unknown[]) => mockCreate(...args),
    updateNetworkSubnet: (...args: unknown[]) => mockUpdate(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const SUBNET: SystemProviderNetworkSubnet = {
  id: 'subnet-1',
  name: 'app-a',
  description: 'App tier',
  cidr_block: '10.0.1.0/24',
  status: 'available',
  is_public: false,
  enabled: true,
  config: {},
  provider_network_id: 'net-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

function renderModal(
  overrides: Partial<React.ComponentProps<typeof SubnetFormModal>> = {},
) {
  const props = {
    networkId: 'net-1',
    subnet: null,
    isOpen: true,
    onClose: jest.fn(),
    onSaved: jest.fn(),
    ...overrides,
  };
  return { props, ...render(<SubnetFormModal {...props} />) };
}

describe('SubnetFormModal', () => {
  beforeEach(() => {
    mockCreate.mockReset();
    mockUpdate.mockReset();
    mockAddNotification.mockReset();
  });

  it('renders nothing when closed', () => {
    const { container } = renderModal({ isOpen: false });
    expect(container).toBeEmptyDOMElement();
  });

  it('creates a subnet under the network it was opened for', async () => {
    mockCreate.mockResolvedValue(SUBNET);
    const { props } = renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'app-b' } });
    fireEvent.change(screen.getByLabelText(/cidr block/i), {
      target: { value: '10.0.2.0/24' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Subnet' }));

    await waitFor(() =>
      expect(mockCreate).toHaveBeenCalledWith(
        'net-1',
        expect.objectContaining({
          name: 'app-b',
          cidr_block: '10.0.2.0/24',
          is_public: false,
          enabled: true,
        }),
      ),
    );
    await waitFor(() => expect(props.onSaved).toHaveBeenCalled());
  });

  it('rejects a CIDR block that is not in prefix form', async () => {
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'app-b' } });
    fireEvent.change(screen.getByLabelText(/cidr block/i), {
      target: { value: '10.0.2.0' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Subnet' }));

    expect(
      await screen.findByText('CIDR block must look like 10.0.1.0/24'),
    ).toBeInTheDocument();
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('blocks submit and reports the missing required fields', async () => {
    renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Add Subnet' }));

    expect(await screen.findByText('Name is required')).toBeInTheDocument();
    expect(screen.getByText('CIDR block is required')).toBeInTheDocument();
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('sends the public flag when it is ticked', async () => {
    mockCreate.mockResolvedValue(SUBNET);
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'edge' } });
    fireEvent.change(screen.getByLabelText(/cidr block/i), {
      target: { value: '10.0.9.0/24' },
    });
    fireEvent.click(screen.getByLabelText(/public subnet/i));
    fireEvent.click(screen.getByRole('button', { name: 'Add Subnet' }));

    await waitFor(() =>
      expect(mockCreate).toHaveBeenCalledWith(
        'net-1',
        expect.objectContaining({ is_public: true }),
      ),
    );
  });

  it('pre-fills and updates in edit mode', async () => {
    mockUpdate.mockResolvedValue(SUBNET);
    renderModal({ subnet: SUBNET });

    expect(screen.getByLabelText(/cidr block/i)).toHaveValue('10.0.1.0/24');

    fireEvent.click(screen.getByRole('button', { name: 'Update Subnet' }));

    await waitFor(() =>
      expect(mockUpdate).toHaveBeenCalledWith(
        'net-1',
        'subnet-1',
        expect.objectContaining({ cidr_block: '10.0.1.0/24' }),
      ),
    );
  });

  it('sends null for a blanked description in edit mode so the column is cleared', async () => {
    mockUpdate.mockResolvedValue(SUBNET);
    renderModal({ subnet: SUBNET });

    fireEvent.change(screen.getByLabelText(/description/i), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: 'Update Subnet' }));

    await waitFor(() => expect(mockUpdate).toHaveBeenCalled());
    const payload = mockUpdate.mock.calls[0][2] as Record<string, unknown>;
    expect(payload).toHaveProperty('description', null);
  });

  it('omits a blank description on create rather than sending null', async () => {
    mockCreate.mockResolvedValue(SUBNET);
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'app-d' } });
    fireEvent.change(screen.getByLabelText(/cidr block/i), {
      target: { value: '10.0.4.0/24' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Subnet' }));

    await waitFor(() => expect(mockCreate).toHaveBeenCalled());
    const payload = mockCreate.mock.calls[0][1] as Record<string, unknown>;
    expect(payload.description).toBeUndefined();
  });

  it('reports a failed create through the notification hook', async () => {
    mockCreate.mockRejectedValue(new Error('overlaps an existing subnet'));
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'app-c' } });
    fireEvent.change(screen.getByLabelText(/cidr block/i), {
      target: { value: '10.0.3.0/24' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Subnet' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create subnet: overlaps an existing subnet',
      }),
    );
  });

  it('labels the form a manual override when asked to', () => {
    renderModal({ manualOverride: true });
    expect(screen.getByText('Manual override')).toBeInTheDocument();
  });
});
