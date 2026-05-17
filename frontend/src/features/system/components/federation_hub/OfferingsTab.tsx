import React, { useState } from 'react';
import { ServiceOfferingsPanel } from '../federation/ServiceOfferingsPanel';
import { ServiceOfferingEditorModal } from '../federation/ServiceOfferingEditorModal';
import type { ServiceOffering } from '../../types/service_delivery.types';

/**
 * Federation Hub > Offerings tab. Composes ServiceOfferingsPanel
 * with the editor modal: clicking a row opens edit; clicking
 * "New Offering" opens create.
 *
 * Plan reference: Decentralized Federation §L.7 + P4.6.8.
 */
export const OfferingsTab: React.FC = () => {
  const [editorOpen, setEditorOpen] = useState(false);
  const [editingOffering, setEditingOffering] = useState<ServiceOffering | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const openCreate = () => {
    setEditingOffering(null);
    setEditorOpen(true);
  };

  const openEdit = (offering: ServiceOffering) => {
    setEditingOffering(offering);
    setEditorOpen(true);
  };

  const handleSaved = () => {
    setRefreshKey((k) => k + 1);
  };

  return (
    <div className="space-y-4">
      <ServiceOfferingsPanel
        refreshKey={refreshKey}
        onCreateClick={openCreate}
        onSelect={openEdit}
      />
      <ServiceOfferingEditorModal
        isOpen={editorOpen}
        onClose={() => setEditorOpen(false)}
        editOffering={editingOffering}
        onSaved={handleSaved}
      />
    </div>
  );
};
