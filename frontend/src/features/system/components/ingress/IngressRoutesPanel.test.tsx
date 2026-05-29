import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { IngressRoutesPanel } from './IngressRoutesPanel';
import { ingressApi } from '../../services/api/ingressApi';
import type { IngressRoute } from '../../services/api/ingressApi';

// Permission gate is mutated per-test via this variable so the same mock
// can return true (read allowed) or false (read denied).
let mockHasPermission = (_permission: string): boolean => true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (permission: string) => mockHasPermission(permission),
  }),
}));

jest.mock('../../services/api/ingressApi', () => ({
  ingressApi: {
    listRoutes: jest.fn(),
  },
}));

const listRoutesMock = ingressApi.listRoutes as jest.MockedFunction<typeof ingressApi.listRoutes>;

const routeFixture = (overrides: Partial<IngressRoute> = {}): IngressRoute => ({
  id: '0190a0c1-0000-7000-8000-000000000001',
  common_name: 'app.example.com',
  sans: ['www.example.com'],
  host_rule: 'Host(`app.example.com`) || Host(`www.example.com`)',
  status: 'valid',
  active: true,
  issuer: 'letsencrypt-prod',
  issued_at: '2026-05-01T00:00:00Z',
  expires_at: '2026-08-01T00:00:00Z',
  days_until_expiry: 64,
  routers: [
    {
      name: 'app-example-com-node-api',
      path_prefix: '/api/v1/system/node_api',
      backend_service: 'powernode-backend',
      backend_url: 'http://127.0.0.1:3000',
      entrypoint: 'websecure',
      tls_resolver: 'mtls-optional@file',
    },
  ],
  public_endpoints: ['https://app.example.com/'],
  ...overrides,
});

describe('IngressRoutesPanel', () => {
  beforeEach(() => {
    mockHasPermission = () => true;
    listRoutesMock.mockReset();
  });

  it('renders a row per route from listRoutes()', async () => {
    listRoutesMock.mockResolvedValue([
      routeFixture(),
      routeFixture({
        id: '0190a0c1-0000-7000-8000-000000000002',
        common_name: 'api.example.com',
        host_rule: 'Host(`api.example.com`)',
        status: 'pending',
        active: false,
      }),
    ]);

    render(<IngressRoutesPanel />);

    await waitFor(() => {
      expect(screen.getAllByTestId('ingress-route-row')).toHaveLength(2);
    });
    expect(listRoutesMock).toHaveBeenCalledTimes(1);
    expect(screen.getByText('Host(`app.example.com`) || Host(`www.example.com`)')).toBeInTheDocument();
    expect(screen.getByText('Host(`api.example.com`)')).toBeInTheDocument();
    // Status badges reflect each cert's lifecycle state.
    expect(screen.getByText('valid')).toBeInTheDocument();
    expect(screen.getByText('pending')).toBeInTheDocument();
  });

  it('shows an empty state when no routes are returned', async () => {
    listRoutesMock.mockResolvedValue([]);

    render(<IngressRoutesPanel />);

    await waitFor(() => {
      expect(screen.getByText(/No ingress routes yet/i)).toBeInTheDocument();
    });
    expect(screen.queryByTestId('ingress-route-row')).not.toBeInTheDocument();
  });

  it('respects the permission gate and never calls the API when read is denied', async () => {
    mockHasPermission = (permission: string) => permission !== 'system.ingress.read';

    render(<IngressRoutesPanel />);

    expect(
      screen.getByText(/don't have permission to view ingress routes/i),
    ).toBeInTheDocument();
    expect(screen.queryByTestId('ingress-routes-list')).not.toBeInTheDocument();
    // Gate short-circuits the fetch entirely.
    await waitFor(() => {
      expect(listRoutesMock).not.toHaveBeenCalled();
    });
  });
});
