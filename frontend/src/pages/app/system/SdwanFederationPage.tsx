import React, { useState, useCallback } from 'react';
import { Globe2 } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  FederationPeerList,
  FederationPeerProposeModal,
  FederationGovernancePanel,
} from '@system/features/system/components/sdwan';

/**
 * SdwanFederationPage — account-scoped (not network-scoped) operator
 * surface for federation peers + governance scan. Federation is a
 * cross-instance concept; one row spans every network.
 */
const SdwanFederationPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const canManage = hasPermission('sdwan.federation.manage');

  const [showPropose, setShowPropose] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  const actions = [
    canManage && {
      label: 'Propose peer',
      onClick: () => setShowPropose(true),
      variant: 'primary' as const,
      icon: Globe2,
    },
  ].filter(Boolean) as { label: string; onClick: () => void; variant: 'primary'; icon: typeof Globe2 }[];

  return (
    <PageContainer
      title="SDWAN Federation"
      description="Cross-Powernode-instance overlay peering. v1 ships data + governance; cross-CA verification + tunnel establishment arrive in a future slice."
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'SDWAN', href: '/app/system/sdwan' },
        { label: 'Federation' },
      ]}
      actions={actions}
    >
      <div className="space-y-4">
        <FederationGovernancePanel refreshKey={refreshKey} />
        <FederationPeerList refreshKey={refreshKey} />
      </div>

      <FederationPeerProposeModal
        isOpen={showPropose}
        onClose={() => setShowPropose(false)}
        onProposed={triggerRefresh}
      />
    </PageContainer>
  );
};

export default SdwanFederationPage;
