import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ExposeServicePanel } from './ExposeServicePanel';
import { acmeDnsCredentialsApi } from '../../services/api/acmeDnsCredentialsApi';
import { sdwanApi } from '../../services/api/sdwanApi';

// Permission gate — manage allowed by default; mutated per-test.
let mockHasPermission = (_permission: string): boolean => true;
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (permission: string) => mockHasPermission(permission),
  }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: mockAddNotification }),
}));

// Concierge hook — captures the brief passed to send().
const mockSend = jest.fn().mockResolvedValue(undefined);
jest.mock('../../hooks/useConcierge', () => ({
  useConcierge: () => ({
    conversationId: 'conv-1',
    agentName: 'Infrastructure Generalist',
    snapshot: null,
    messages: [],
    pending: false,
    error: null,
    send: mockSend,
    confirmAction: jest.fn(),
    reset: jest.fn(),
  }),
}));

jest.mock('../../services/api/acmeDnsCredentialsApi', () => ({
  acmeDnsCredentialsApi: { list: jest.fn() },
}));

jest.mock('../../services/api/sdwanApi', () => ({
  sdwanApi: { getNetworks: jest.fn(), getPeers: jest.fn() },
}));

const listCredsMock = acmeDnsCredentialsApi.list as jest.Mock;
const getNetworksMock = sdwanApi.getNetworks as jest.Mock;
const getPeersMock = sdwanApi.getPeers as jest.Mock;

async function fillRequiredFields() {
  fireEvent.change(screen.getByLabelText('Public hostname'), {
    target: { value: 'app.example.com' },
  });
  fireEvent.change(screen.getByLabelText('SDWAN network'), { target: { value: 'net-1' } });
  await waitFor(() => {
    expect(screen.getByRole('option', { name: /fd00::1/ })).toBeInTheDocument();
  });
  fireEvent.change(screen.getByLabelText('SDWAN hub peer'), { target: { value: 'peer-1' } });
  fireEvent.change(screen.getByLabelText('VIP CIDR'), {
    target: { value: 'fd00:dead:beef::1/128' },
  });
  fireEvent.change(screen.getByLabelText('Backend port'), { target: { value: '8080' } });
  fireEvent.change(screen.getByLabelText('DNS credential'), { target: { value: 'cred-1' } });
}

describe('ExposeServicePanel', () => {
  beforeEach(() => {
    mockHasPermission = () => true;
    mockSend.mockClear();
    mockSend.mockResolvedValue(undefined);
    mockAddNotification.mockClear();
    // resetMocks: true wipes inline resolved values between tests — re-arm here.
    listCredsMock.mockResolvedValue({
      credentials: [{ id: 'cred-1', name: 'Cloudflare', provider: 'cloudflare' }],
    });
    getNetworksMock.mockResolvedValue({
      networks: [{ id: 'net-1', name: 'Core', slug: 'core' }],
    });
    getPeersMock.mockResolvedValue({
      peers: [{ id: 'peer-1', assigned_address: 'fd00::1', status: 'active' }],
    });
  });

  it('offers only http/https protocols (tcp removed)', async () => {
    render(<ExposeServicePanel />);
    await waitFor(() => {
      expect(screen.getByRole('option', { name: 'Core (core)' })).toBeInTheDocument();
    });

    const protocolSelect = screen.getByLabelText('Protocol');
    const options = Array.from(protocolSelect.querySelectorAll('option')).map((o) => o.textContent);
    expect(options).toEqual(['http', 'https']);
    expect(screen.queryByRole('option', { name: 'tcp' })).not.toBeInTheDocument();
  });

  it('renders a required vip_cidr field with host-CIDR help text', () => {
    render(<ExposeServicePanel />);
    expect(screen.getByLabelText('VIP CIDR')).toBeInTheDocument();
    expect(screen.getByText(/host CIDR .* within the SDWAN network's \/64/i)).toBeInTheDocument();
  });

  it('keeps submit disabled until vip_cidr is supplied', async () => {
    render(<ExposeServicePanel />);
    await waitFor(() => {
      expect(screen.getByRole('option', { name: 'Core (core)' })).toBeInTheDocument();
    });

    // Fill everything except vip_cidr.
    fireEvent.change(screen.getByLabelText('Public hostname'), {
      target: { value: 'app.example.com' },
    });
    fireEvent.change(screen.getByLabelText('SDWAN network'), { target: { value: 'net-1' } });
    await waitFor(() => {
      expect(screen.getByRole('option', { name: /fd00::1/ })).toBeInTheDocument();
    });
    fireEvent.change(screen.getByLabelText('SDWAN hub peer'), { target: { value: 'peer-1' } });
    fireEvent.change(screen.getByLabelText('Backend port'), { target: { value: '8080' } });
    fireEvent.change(screen.getByLabelText('DNS credential'), { target: { value: 'cred-1' } });

    const submit = screen.getByRole('button', { name: /Submit expose request/i });
    expect(submit).toBeDisabled();

    fireEvent.change(screen.getByLabelText('VIP CIDR'), {
      target: { value: 'fd00:dead:beef::1/128' },
    });
    expect(submit).toBeEnabled();
  });

  it('includes vip_cidr in the brief submitted via the concierge path', async () => {
    render(<ExposeServicePanel />);
    await waitFor(() => {
      expect(screen.getByRole('option', { name: 'Core (core)' })).toBeInTheDocument();
    });

    await fillRequiredFields();
    fireEvent.click(screen.getByRole('button', { name: /Submit expose request/i }));

    await waitFor(() => {
      expect(mockSend).toHaveBeenCalledTimes(1);
    });
    const brief = mockSend.mock.calls[0][0] as string;
    expect(brief).toContain('- vip_cidr: fd00:dead:beef::1/128');
  });
});
