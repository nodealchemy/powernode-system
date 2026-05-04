import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { ModuleCard } from './ModuleCard';
import type { MarketplaceModuleCard } from '../../services/api/marketplaceApi';

describe('ModuleCard', () => {
  const baseModule: MarketplaceModuleCard = {
    id: 'm1',
    name: 'nginx-base',
    description: 'Hardened nginx baseline',
    trust_tier: 'verified-publisher',
    variety: 'subscription',
    current_version_number: '1.4.0',
    assignment_count: 3,
    platform: 'ubuntu-24.04',
    category: 'web',
  };

  it('renders the module name and trust tier badge', () => {
    render(<ModuleCard module={baseModule} onClick={jest.fn()} />);
    expect(screen.getByText('nginx-base')).toBeInTheDocument();
    expect(screen.getByText('verified-publisher')).toBeInTheDocument();
  });

  it('renders description, version, assignments, and platform', () => {
    render(<ModuleCard module={baseModule} onClick={jest.fn()} />);

    expect(screen.getByText('Hardened nginx baseline')).toBeInTheDocument();
    expect(screen.getByText('v1.4.0')).toBeInTheDocument();
    expect(screen.getByText('3 nodes')).toBeInTheDocument();
    expect(screen.getByText('ubuntu-24.04')).toBeInTheDocument();
  });

  it('uses singular "node" when assignment_count is 1', () => {
    render(<ModuleCard module={{ ...baseModule, assignment_count: 1 }} onClick={jest.fn()} />);
    expect(screen.getByText('1 node')).toBeInTheDocument();
  });

  it('omits the description block when not provided', () => {
    render(<ModuleCard module={{ ...baseModule, description: undefined }} onClick={jest.fn()} />);
    expect(screen.queryByText('Hardened nginx baseline')).not.toBeInTheDocument();
  });

  it('omits the platform tag when not provided', () => {
    render(<ModuleCard module={{ ...baseModule, platform: undefined }} onClick={jest.fn()} />);
    expect(screen.queryByText('ubuntu-24.04')).not.toBeInTheDocument();
  });

  it('falls back to community trust styling for unknown tiers', () => {
    const { container } = render(
      <ModuleCard module={{ ...baseModule, trust_tier: 'unrecognized-tier' }} onClick={jest.fn()} />
    );
    // Community-tier styles use bg-theme-warning per TRUST_TIER_STYLES fallback
    expect(container.querySelector('.bg-theme-warning')).toBeInTheDocument();
  });

  it('invokes onClick when the card is clicked', () => {
    const handler = jest.fn();
    render(<ModuleCard module={baseModule} onClick={handler} />);
    fireEvent.click(screen.getByText('nginx-base'));
    expect(handler).toHaveBeenCalledTimes(1);
  });
});
