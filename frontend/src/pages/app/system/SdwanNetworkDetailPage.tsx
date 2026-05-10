import React, { useEffect, useState, useCallback } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { NetworkDetailModal } from '@system/features/system/components/sdwan';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type { SdwanNetwork } from '@system/features/system/types/sdwan.types';

/**
 * SdwanNetworkDetailPage — thin wrapper that opens NetworkDetailModal
 * for the network in the URL params. Kept solely so the legacy URL
 * /app/system/sdwan/networks/:id remains bookmarkable; the actual
 * detail surface is the modal.
 *
 * On modal close, navigates back to the SDWAN networks tab. Per-instance
 * fetch (rather than passing through a stub network) ensures direct URL
 * navigation works without depending on list state from the SDWAN hub.
 *
 * Refactored from the prior 7-tab page into a wrapper because the
 * standalone page concept conflicts with the modal-first management UX.
 */
const SdwanNetworkDetailPage: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();

  const [network, setNetwork] = useState<SdwanNetwork | null>(null);
  const [error, setError] = useState<string | null>(null);

  const handleClose = useCallback(() => {
    navigate('/app/system/sdwan/networks');
  }, [navigate]);

  useEffect(() => {
    if (!id) return;
    let cancelled = false;
    (async () => {
      try {
        const n = await sdwanApi.getNetwork(id);
        if (!cancelled) setNetwork(n);
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load network');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id]);

  if (error) {
    return (
      <div className="p-4 bg-theme-danger text-theme-danger rounded m-4">
        {error}
      </div>
    );
  }

  // Render the modal in open state. NetworkDetailModal returns null
  // when network is null, so we get a clean blank-state during fetch.
  return (
    <NetworkDetailModal
      network={network}
      isOpen={network !== null}
      onClose={handleClose}
    />
  );
};

export default SdwanNetworkDetailPage;
