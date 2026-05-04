import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import {
  FederationPeerList,
  FederationPeerProposeModal,
  FederationGovernancePanel,
} from '@system/features/system/components/sdwan';

interface FederationTabProps {
  onActionsReady?: (handle: { openPropose: () => void } | null) => void;
}

export const FederationTab: React.FC<FederationTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const _canManage = hasPermission('sdwan.federation.manage');
  void _canManage; // gating happens at the parent hub via PageContainer.actions

  const [showPropose, setShowPropose] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  useEffect(() => {
    onActionsReady?.({ openPropose: () => setShowPropose(true) });
    return () => onActionsReady?.(null);
  }, [onActionsReady]);

  return (
    <div className="space-y-4">
      <FederationGovernancePanel refreshKey={refreshKey} />
      <FederationPeerList refreshKey={refreshKey} />

      <FederationPeerProposeModal
        isOpen={showPropose}
        onClose={() => setShowPropose(false)}
        onProposed={triggerRefresh}
      />
    </div>
  );
};
