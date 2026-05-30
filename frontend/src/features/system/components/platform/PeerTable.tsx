import React from 'react';
import { Clock } from 'lucide-react';
import { PeerStatusPill } from './PeerStatusPill';
import type { PlatformPeerSummary } from '../../types/peer.types';

/**
 * PeerTable / PeerRow — shared presentational peer table.
 *
 * Single source of truth for the Remote URL / Status / Last Heartbeat columns
 * (and the PeerStatusPill + heartbeat formatting) that were copy-pasted across
 * PeersPanel, PeerControlPanel, and PeerLivenessMonitor. Each consumer keeps
 * its own variant-specific behavior by composing the shared cells:
 *
 *   - PeersPanel        — extra Role / Mode / Endpoints columns + a revoke action
 *   - PeerControlPanel  — an Actions column with arm-and-confirm revoke
 *   - PeerLivenessMonitor — a live-event row "live" pulse + stale-heartbeat highlight
 *
 * The shared cells are exposed as standalone sub-components (PeerUrlCell,
 * PeerStatusCell, PeerHeartbeatCell) so a row can interleave them with its own
 * extra <td>s in whatever column order it declares.
 *
 * Plan reference: Decentralized Federation §I + P7.1 / Phase 3.
 */

interface PeerTableProps {
  /** Column header labels, left-to-right; the last header may be right-aligned. */
  columns: Array<{ label: string; align?: 'left' | 'right' }>;
  children: React.ReactNode;
}

export const PeerTable: React.FC<PeerTableProps> = ({ columns, children }) => (
  <table className="w-full text-sm">
    <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
      <tr>
        {columns.map((col) => (
          <th
            key={col.label}
            className={`px-4 py-2 font-medium ${col.align === 'right' ? 'text-right' : 'text-left'}`}
          >
            {col.label}
          </th>
        ))}
      </tr>
    </thead>
    <tbody>{children}</tbody>
  </table>
);

/**
 * Remote URL cell. `live` renders the pulse dot used by the liveness monitor;
 * omit it everywhere else.
 */
export const PeerUrlCell: React.FC<{ peer: PlatformPeerSummary; live?: boolean }> = ({
  peer,
  live = false,
}) => (
  <td className="px-4 py-3 text-theme-primary font-mono text-xs">
    {live ? (
      <span className="inline-flex items-center gap-2">
        <span
          className="w-1.5 h-1.5 rounded-full bg-theme-success-solid animate-pulse"
          title="Live event received this session"
        />
        {peer.remote_instance_url}
      </span>
    ) : (
      peer.remote_instance_url
    )}
  </td>
);

export const PeerStatusCell: React.FC<{ peer: PlatformPeerSummary }> = ({ peer }) => (
  <td className="px-4 py-3">
    <PeerStatusPill status={peer.status} />
  </td>
);

/**
 * Last-heartbeat cell. When `stale` is true the timestamp is rendered in the
 * warning color with a "stale" suffix (liveness monitor only).
 */
export const PeerHeartbeatCell: React.FC<{ peer: PlatformPeerSummary; stale?: boolean }> = ({
  peer,
  stale = false,
}) => (
  <td className="px-4 py-3 text-xs">
    {peer.last_heartbeat_at ? (
      <span
        className={`inline-flex items-center gap-1 ${stale ? 'text-theme-warning' : 'text-theme-secondary'}`}
      >
        <Clock className="w-3 h-3" />
        {new Date(peer.last_heartbeat_at).toLocaleString()}
        {stale && <span className="ml-1 font-medium">stale</span>}
      </span>
    ) : (
      <span className="text-theme-tertiary">never</span>
    )}
  </td>
);

export default PeerTable;
