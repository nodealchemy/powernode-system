import React, { useState } from 'react';
import { ChildrenPanel } from '../federation/ChildrenPanel';
import { SpawnPlatformModal } from '../federation/SpawnPlatformModal';
import type { ChildPeerSummary } from '../../types/spawn.types';

/**
 * Federation Hub > Children tab. Composes ChildrenPanel +
 * SpawnPlatformModal. Plan reference: Decentralized Federation §H + P6.
 */
export const ChildrenTab: React.FC = () => {
  const [spawnOpen, setSpawnOpen] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  const handleSelect = (_child: ChildPeerSummary) => {
    // Future: open a detail modal with full timeline + audit.
    // v1: row click is informational only.
  };

  return (
    <div className="space-y-4">
      <ChildrenPanel
        refreshKey={refreshKey}
        onSpawnClick={() => setSpawnOpen(true)}
        onSelect={handleSelect}
      />
      <SpawnPlatformModal
        isOpen={spawnOpen}
        onClose={() => setSpawnOpen(false)}
        onSpawned={() => setRefreshKey((k) => k + 1)}
      />
    </div>
  );
};
