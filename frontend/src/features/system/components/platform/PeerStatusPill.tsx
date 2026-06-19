import React from 'react';
import type { PeerStatus } from '../../types/peer.types';

/**
 * PeerStatusPill — shared status badge for a platform federation peer.
 *
 * Single source of truth for the peer-status → theme-class mapping. Extracted
 * to remove the byte-identical `StatusPill` that was copy-pasted across
 * PeersPanel (Compute infra tab), PeerControlPanel, and PeerLivenessMonitor
 * (Federation Hub Control + Monitor tabs).
 */
const STYLE_BY_STATUS: Record<PeerStatus, string> = {
  proposed: 'bg-theme-background-tertiary text-theme-secondary',
  accepted: 'bg-theme-info-bg text-theme-info-fg',
  enrolled: 'bg-theme-info-bg text-theme-info-fg',
  active: 'bg-theme-success-bg text-theme-success-fg',
  degraded: 'bg-theme-warning-bg text-theme-warning-fg',
  suspended: 'bg-theme-warning-bg text-theme-warning-fg',
  revoked: 'bg-theme-danger-bg text-theme-danger-fg',
};

export const PeerStatusPill: React.FC<{ status: PeerStatus }> = ({ status }) => (
  <span className={`inline-block px-2 py-0.5 rounded text-xs font-medium ${STYLE_BY_STATUS[status]}`}>
    {status}
  </span>
);

export default PeerStatusPill;
