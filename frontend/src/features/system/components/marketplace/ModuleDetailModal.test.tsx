import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ModuleDetailModal } from './ModuleDetailModal';
import { marketplaceApi } from '../../services/api/marketplaceApi';

jest.mock('../../services/api/marketplaceApi', () => ({
  marketplaceApi: {
    get: jest.fn(),
  },
}));

const mockGet = marketplaceApi.get as jest.MockedFunction<typeof marketplaceApi.get>;

describe('ModuleDetailModal', () => {
  beforeEach(() => {
    mockGet.mockReset();
  });

  it('renders the loading state initially', () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves
    render(<ModuleDetailModal moduleId="m-1" onClose={jest.fn()} />);
    expect(screen.getByText('Loading...')).toBeInTheDocument();
  });

  it('renders module details after a successful fetch', async () => {
    mockGet.mockResolvedValue({
      module: {
        id: 'm-1',
        name: 'nginx-base',
        description: 'Hardened nginx',
        trust_tier: 'verified-publisher',
        variety: 'subscription',
        current_version_number: '1.4.0',
        category: 'web',
        platform: 'ubuntu-24.04',
        assignment_count: 5,
      },
      recent_versions: [
        { id: 'v1', version_number: '1.4.0', created_at: '2026-05-01T10:00:00Z' },
        { id: 'v0', version_number: '1.3.0', created_at: '2026-04-01T10:00:00Z' },
      ],
      dependencies: [
        { id: 'd1', required_module_id: 'd-mod', required_module_name: 'libssl', required_version: '3.0' },
      ],
    });

    render(<ModuleDetailModal moduleId="m-1" onClose={jest.fn()} />);

    await waitFor(() => expect(screen.getByText('nginx-base')).toBeInTheDocument());

    expect(screen.getByText('Hardened nginx')).toBeInTheDocument();
    expect(screen.getByText('verified-publisher')).toBeInTheDocument();
    expect(screen.getByText('subscription')).toBeInTheDocument();
    expect(screen.getByText('v1.4.0')).toBeInTheDocument();
    expect(screen.getByText('libssl')).toBeInTheDocument();
  });

  it('renders an error state when fetch fails', async () => {
    mockGet.mockRejectedValue(new Error('boom'));

    render(<ModuleDetailModal moduleId="m-bad" onClose={jest.fn()} />);

    await waitFor(() => expect(screen.getByText('boom')).toBeInTheDocument());
  });

  it('omits the recent-versions section when none returned', async () => {
    mockGet.mockResolvedValue({
      module: {
        id: 'm-1', name: 'tiny', description: '', trust_tier: 'community',
        variety: 'subscription', current_version_number: '0.1.0',
        assignment_count: 0,
      },
      recent_versions: [],
      dependencies: [],
    });

    render(<ModuleDetailModal moduleId="m-1" onClose={jest.fn()} />);
    await waitFor(() => expect(screen.getByText('tiny')).toBeInTheDocument());

    expect(screen.queryByText(/Recent versions/i)).not.toBeInTheDocument();
    expect(screen.queryByText(/Dependencies/i)).not.toBeInTheDocument();
  });

  it('invokes onClose when Close button clicked', async () => {
    mockGet.mockResolvedValue({
      module: {
        id: 'm-1', name: 'tiny', description: '', trust_tier: 'community',
        variety: 'subscription', current_version_number: '0.1.0',
        assignment_count: 0,
      },
      recent_versions: [],
      dependencies: [],
    });

    const handler = jest.fn();
    render(<ModuleDetailModal moduleId="m-1" onClose={handler} />);
    await waitFor(() => screen.getByText('tiny'));

    fireEvent.click(screen.getByText('Close'));
    expect(handler).toHaveBeenCalled();
  });
});
