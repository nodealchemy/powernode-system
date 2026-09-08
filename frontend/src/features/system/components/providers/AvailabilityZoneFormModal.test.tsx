import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { AvailabilityZoneFormModal } from './AvailabilityZoneFormModal';
import type { SystemProviderAvailabilityZone } from '@system/features/system/types/system.types';

const mockCreate = jest.fn();
const mockUpdate = jest.fn();

jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    createProviderAvailabilityZone: (...args: unknown[]) => mockCreate(...args),
    updateProviderAvailabilityZone: (...args: unknown[]) => mockUpdate(...args),
  },
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

const ZONE: SystemProviderAvailabilityZone = {
  id: 'az-1',
  name: 'Zone A',
  zone_code: 'us-east-1a',
  status: 'available',
  enabled: true,
  capabilities: {},
  provider_region_id: 'reg-1',
  operational: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
};

function renderModal(
  overrides: Partial<React.ComponentProps<typeof AvailabilityZoneFormModal>> = {},
) {
  const props = {
    providerId: 'prov-1',
    regionId: 'reg-1',
    zone: null,
    isOpen: true,
    onClose: jest.fn(),
    onSaved: jest.fn(),
    ...overrides,
  };
  return { props, ...render(<AvailabilityZoneFormModal {...props} />) };
}

describe('AvailabilityZoneFormModal', () => {
  beforeEach(() => {
    mockCreate.mockReset();
    mockUpdate.mockReset();
    mockAddNotification.mockReset();
  });

  it('renders nothing when closed', () => {
    const { container } = renderModal({ isOpen: false });
    expect(container).toBeEmptyDOMElement();
  });

  it('creates a zone scoped to the provider and region it was opened for', async () => {
    mockCreate.mockResolvedValue(ZONE);
    const { props } = renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Zone B' } });
    fireEvent.change(screen.getByLabelText(/zone code/i), {
      target: { value: 'us-east-1b' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Zone' }));

    await waitFor(() =>
      expect(mockCreate).toHaveBeenCalledWith('prov-1', 'reg-1', {
        name: 'Zone B',
        zone_code: 'us-east-1b',
        status: 'available',
        enabled: true,
      }),
    );
    await waitFor(() => expect(props.onSaved).toHaveBeenCalled());
  });

  it('blocks submit and reports the missing required fields', async () => {
    renderModal();

    fireEvent.click(screen.getByRole('button', { name: 'Add Zone' }));

    expect(await screen.findByText('Name is required')).toBeInTheDocument();
    expect(screen.getByText('Zone code is required')).toBeInTheDocument();
    expect(mockCreate).not.toHaveBeenCalled();
  });

  it('sends the chosen status', async () => {
    mockCreate.mockResolvedValue(ZONE);
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Zone C' } });
    fireEvent.change(screen.getByLabelText(/zone code/i), {
      target: { value: 'us-east-1c' },
    });
    fireEvent.change(screen.getByLabelText(/status/i), { target: { value: 'impaired' } });
    fireEvent.click(screen.getByRole('button', { name: 'Add Zone' }));

    await waitFor(() =>
      expect(mockCreate).toHaveBeenCalledWith(
        'prov-1',
        'reg-1',
        expect.objectContaining({ status: 'impaired' }),
      ),
    );
  });

  it('pre-fills and updates in edit mode', async () => {
    mockUpdate.mockResolvedValue(ZONE);
    renderModal({ zone: ZONE });

    expect(screen.getByLabelText(/zone code/i)).toHaveValue('us-east-1a');

    fireEvent.click(screen.getByRole('button', { name: 'Update Zone' }));

    await waitFor(() =>
      expect(mockUpdate).toHaveBeenCalledWith(
        'prov-1',
        'reg-1',
        'az-1',
        expect.objectContaining({ zone_code: 'us-east-1a' }),
      ),
    );
  });

  it('reports a failed create through the notification hook', async () => {
    mockCreate.mockRejectedValue(new Error('zone code taken'));
    renderModal();

    fireEvent.change(screen.getByLabelText(/^name/i), { target: { value: 'Zone D' } });
    fireEvent.change(screen.getByLabelText(/zone code/i), {
      target: { value: 'us-east-1d' },
    });
    fireEvent.click(screen.getByRole('button', { name: 'Add Zone' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith({
        type: 'error',
        message: 'Failed to create availability zone: zone code taken',
      }),
    );
  });

  it('labels the form a manual override when asked to', () => {
    renderModal({ manualOverride: true });
    expect(screen.getByText('Manual override')).toBeInTheDocument();
  });
});
