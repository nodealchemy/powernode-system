import React, { useState } from 'react';
import { ServiceSubscriptionsPanel } from '../federation/ServiceSubscriptionsPanel';
import type { ServiceSubscription } from '../../types/service_delivery.types';

/**
 * Federation Hub > Subscriptions tab. Lists this platform's
 * subscriptions to remote peers' services.
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8.
 */
export const SubscriptionsTab: React.FC = () => {
  // Cancel via the inline action triggers a fetch in the panel itself,
  // but we keep a refreshKey here so the parent can force-refresh from
  // outside if needed (e.g., after a subscribe completes in a sibling tab).
  const [refreshKey] = useState(0);

  const handleSelect = (_sub: ServiceSubscription) => {
    // Future: open a detail modal with full audit timeline.
    // For v1 the row click is informational only.
  };

  return (
    <div className="space-y-4">
      <ServiceSubscriptionsPanel refreshKey={refreshKey} onSelect={handleSelect} />
    </div>
  );
};
