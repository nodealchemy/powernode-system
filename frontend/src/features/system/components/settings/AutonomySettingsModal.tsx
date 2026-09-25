import React, { useState } from 'react';
import { Settings } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { TabContainer } from '@/shared/components/layout/TabContainer';
import { ApprovalChainList } from '@/shared/components/approval-chains/ApprovalChainList';
import { InterventionPoliciesPanel } from '@/features/ai/autonomy/components/InterventionPoliciesPanel';

interface AutonomySettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

const TABS = [
  { id: 'policies', label: 'Intervention Policies' },
  { id: 'chains', label: 'Approval Chains' },
];

/**
 * The Operations hub's autonomy settings. Both tabs are core's: Policies is the
 * intervention-policy panel scoped to the domains this extension presents
 * (register.ts), which owns the grouping, per-agent editors, dirty tracking and
 * stale-server warning; Approval Chains is the shared chain list. This modal
 * only frames them.
 */
export const AutonomySettingsModal: React.FC<AutonomySettingsModalProps> = ({ isOpen, onClose }) => {
  const [activeTab, setActiveTab] = useState('policies');

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      variant="centered"
      size="6xl"
      title="System Autonomy Settings"
      icon={<Settings className="w-6 h-6" />}
      subtitle="Configure per-action intervention policies and approval chains"
    >
      <TabContainer
        tabs={TABS}
        activeTab={activeTab}
        onTabChange={setActiveTab}
        renderContent={(tab) =>
          tab === 'chains' ? <ApprovalChainList /> : <InterventionPoliciesPanel namespace="system" />
        }
      />
    </Modal>
  );
};

export default AutonomySettingsModal;
