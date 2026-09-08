import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { InstanceTypeFormModal } from './InstanceTypeFormModal';
import type { SystemProviderInstanceType } from '@system/features/system/types/system.types';

const mockCreate = jest.fn();
const mockUpdate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createProviderInstanceType: (...args: unknown[]) => mockCreate(...args),
    updateProviderInstanceType: (...args: unknown[]) => mockUpdate(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const INSTANCE_TYPE: SystemProviderInstanceType = {
  id: 'it-1',
  name: 'General Medium',
  instance_type_code: 't3.medium',
  description: 'Two cores',
  vcpus: 2,
  memory_mb: 4096,
  storage_gb: 50,
  hourly_price: 0.04,
  enabled: true,
  specs: {},
  provider_id: 'prov-1',
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

function renderModal(
  overrides: Partial<React.ComponentProps<typeof InstanceTypeFormModal>> = {},
) {
  const props = {
    providerId: 'prov-1',
    instanceType: null,
    isOpen: true,
    onClose: jest.fn(),
    onSaved: jest.fn(),
    ...overrides,
  };
  return { props, ...render(<InstanceTypeFormModal {...props} />) };
}

describe('InstanceTypeFormModal', () => {
  beforeEach(() => {
    mockCreate.mockReset();
    mockUpdate.mockReset();
    mockAddNotification.mockReset();
  });

  it('renders nothing when closed', () => {
    const { container } = renderModal({ isOpen: false });
    expect(container).toBeEmptyDOMElement();
  });

  it('creates an instance type with the numeric fields coerced', async () => {
    mockCreate.mockResolvedValue(INSTANCE_TYPE);
    const { props } = renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Large' } });
    fireEvent.change(screen.getByLabelText(/instance type code/i), {
      target: { value: 'm5.large' },
    });
    fireEvent.change(screen.getByLabelText(/vcpus/i), { target: { value: '4' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add Instance Type' }));

    await waitFor(() =>
      expect(mockCreate).toHaveBeenCalledWith(
        'prov-1',
        expect.objectContaining({
          name: 'Large',
          instance_type_code: 'm5.large',
          vcpus: 4,
          enabled: true,
        }),
      ),
    );
    await waitFor(() => expect(props.onSaved).toHaveBeenCalled());
    expect(props.onClose).toHaveBeenCalled();
  });

  it('omits a blank numeric field rather than sending zero', async () => {
    mockCreate.mockResolvedValue(INSTANCE_TYPE);
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Bare' } });
    fireEvent.change(screen.getByLabelText(/instance type code/i), {
      target: { value: 'bare.metal' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Instance Type' }));

    await waitFor(() => expect(mockCreate).toHaveBeenCalled());
    const payload = mockCreate.mock.calls[0][1] as Record<string, unknown>;
    expect(payload.vcpus).toBeUndefined();
    expect(payload.memory_mb).toBeUndefined();
  });

  it('blocks submit and reports the missing required fields', async () => {
    renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Add Instance Type' }));

    expect(await screen.findByText('Name is required')).toBeInTheDocument();
    expect(screen.getByText('Instance type code is required')).toBeInTheDocument();
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('rejects a non-numeric vCPU value', async () => {
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Large' } });
    fireEvent.change(screen.getByLabelText(/instance type code/i), {
      target: { value: 'm5.large' },
    });
    fireEvent.change(screen.getByLabelText(/vcpus/i), { target: { value: 'four' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add Instance Type' }));

    expect(await screen.findByText('vCPUs must be a number')).toBeInTheDocument();
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('pre-fills and updates in edit mode', async () => {
    mockUpdate.mockResolvedValue(INSTANCE_TYPE);
    renderModal({ instanceType: INSTANCE_TYPE });

    expect(screen.getByLabelText(/^name/i)).toHaveValue('General Medium');
    expect(screen.getByLabelText(/vcpus/i)).toHaveValue('2');

    fireEvent.click(screen.getByRole('button', { name: 'Update Instance Type' }));

    await waitFor(() =>
      expect(mockUpdate).toHaveBeenCalledWith(
        'prov-1',
        'it-1',
        expect.objectContaining({ instance_type_code: 't3.medium' }),
      ),
    );
  });

  it('sends null for a blanked field in edit mode so the column is cleared', async () => {
    mockUpdate.mockResolvedValue(INSTANCE_TYPE);
    renderModal({ instanceType: INSTANCE_TYPE });

    fireEvent.change(screen.getByLabelText(/vcpus/i), { target: { value: '' } });
    fireEvent.change(screen.getByLabelText(/description/i), { target: { value: '' } });
    fireEvent.click(screen.getByRole('button', { name: 'Update Instance Type' }));

    await waitFor(() => expect(mockUpdate).toHaveBeenCalled());
    const payload = mockUpdate.mock.calls[0][2] as Record<string, unknown>;
    // An omitted key would leave the old value in place behind a success toast.
    expect(payload).toHaveProperty('vcpus', null);
    expect(payload).toHaveProperty('description', null);
  });

  it('reports a failed create through the notification hook', async () => {
    mockCreate.mockRejectedValue(new Error('code already taken'));
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Large' } });
    fireEvent.change(screen.getByLabelText(/instance type code/i), {
      target: { value: 'm5.large' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Instance Type' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create instance type: code already taken',
      }),
    );
  });

  it('labels the form a manual override when the provider has a cloud connection', () => {
    renderModal({ manualOverride: true });

    expect(screen.getByText('Manual override')).toBeInTheDocument();
    expect(screen.getByText(/normally\s+populated by Sync catalog/)).toBeInTheDocument();
  });

  it('carries no manual-override label for a provider with no connection', () => {
    renderModal();

    expect(screen.queryByText('Manual override')).not.toBeInTheDocument();
  });
});
