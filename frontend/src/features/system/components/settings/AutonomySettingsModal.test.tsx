import { render, screen, fireEvent } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';
import { AutonomySettingsModal } from './AutonomySettingsModal';

// The Operations hub's "Settings" action: two tabs. Policies is core's
// intervention-policy panel scoped to this extension's domains; Approval
// Chains is core's shared chain list.

jest.mock('@/features/ai/autonomy/components/InterventionPoliciesPanel', () => ({
  InterventionPoliciesPanel: ({ namespace }: { namespace?: string }) => (
    <div data-testid="core-policy-panel" data-namespace={namespace ?? ''} />
  ),
}));

jest.mock('@/shared/components/approval-chains/ApprovalChainList', () => ({
  ApprovalChainList: () => <div data-testid="approval-chain-list" />,
}));

const renderModal = (isOpen = true) =>
  render(
    <MemoryRouter>
      <AutonomySettingsModal isOpen={isOpen} onClose={jest.fn()} />
    </MemoryRouter>
  );

describe('AutonomySettingsModal', () => {
  it('opens on Policies: core\'s panel scoped to the system namespace', () => {
    renderModal();

    expect(screen.getByTestId('core-policy-panel')).toHaveAttribute('data-namespace', 'system');
    expect(screen.queryByTestId('approval-chain-list')).not.toBeInTheDocument();
  });

  it('switches to the Approval Chains tab and back', () => {
    renderModal();

    fireEvent.click(screen.getByRole('tab', { name: 'Approval Chains' }));
    expect(screen.getByTestId('approval-chain-list')).toBeInTheDocument();
    expect(screen.queryByTestId('core-policy-panel')).not.toBeInTheDocument();
    expect(screen.getByRole('tab', { name: 'Approval Chains' })).toHaveAttribute('aria-selected', 'true');

    fireEvent.click(screen.getByRole('tab', { name: 'Intervention Policies' }));
    expect(screen.getByTestId('core-policy-panel')).toBeInTheDocument();
  });

  it('renders nothing while closed', () => {
    renderModal(false);

    expect(screen.queryByTestId('core-policy-panel')).not.toBeInTheDocument();
  });
});
