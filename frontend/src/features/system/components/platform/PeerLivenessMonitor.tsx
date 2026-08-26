import React, { useEffect, useMemo, useState } from 'react';
import { Network, AlertTriangle, RefreshCw, Wifi, WifiOff } from 'lucide-react';
import { useWebSocket } from '@/shared/hooks/useWebSocket';
import { useAuth } from '@/shared/hooks/useAuth';
import { logger } from '@/shared/utils/logger';
import { usePlatformPeers } from '../../hooks/usePlatformPeers';
import { PeerTable, PeerUrlCell, PeerStatusCell, PeerHeartbeatCell } from './PeerTable';
import type { PlatformPeerSummary, PeerStatus } from '../../types/peer.types';
import { PeerDetailDrawer } from './PeerDetailDrawer';

/**
 * PeerLivenessMonitor — read-only, real-time federation peer liveness for
 * the Federation Hub's Monitor tab.
 *
 * Composes the shared usePlatformPeers list + PeerDetailDrawer, and layers
 * a live SystemFleetChannel subscription on top: federation heartbeat /
 * peer-status FleetEvents (kind prefix `system.federation` /
 * `system.platform_peer` / `decision.*` referencing a peer) bump the matching
 * row's status + last-heartbeat in place without a refetch. Mirrors the
 * subscription wiring in FleetDashboardPage (account-scoped
 * `SystemFleetChannel`, single-event-object payload) and the
 * MissionChannel-subscribe shape in StepProgressStream.
 *
 * Net-new wiring (per the Phase 3 contract): no live federation surface
 * existed before — PeersPanel is poll-only. This monitor is purely
 * presentational + read-only; all mutation lives in the Control tab's
 * PeerControlPanel.
 *
 * Plan reference: Phase 3 (Federation & Multi-Site) — Monitor.
 */

const HEARTBEAT_STALE_MS = 90_000;

interface PeerLivenessMonitorProps {
  /** Bumped by the parent to force a manual list refetch. */
  refreshKey?: number;
}

export const PeerLivenessMonitor: React.FC<PeerLivenessMonitorProps> = ({ refreshKey }) => {
  const { subscribe, isConnected } = useWebSocket();
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const { peers, setPeers, loading, error, refetch } = usePlatformPeers();
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [livePeerIds, setLivePeerIds] = useState<Set<string>>(() => new Set());
  // Tick once a minute so the "stale heartbeat" highlight re-evaluates even
  // when no new events arrive.
  const [, setNow] = useState<number>(() => Date.now());

  // Force a refetch when the parent bumps refreshKey.
  useEffect(() => {
    void refetch();
  }, [refetch, refreshKey]);

  useEffect(() => {
    const interval = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(interval);
  }, []);

  // Live federation events → in-place row update. The current broadcast
  // contract (System::FederationPeer#broadcast_peer_state!) stamps the peer id
  // as payload.federation_peer_id — this component is a declared reader of
  // that contract (see the comment at the emit site in federation_peer.rb).
  // payload.remote_instance_url is a live alternate match path, not a fallback:
  // current emitters stamp it alongside federation_peer_id (e.g.
  // Sdwan::FederationGovernance#build_finding).
  //
  // The former payload.platform_peer_id / payload.peer_id fallbacks are GONE.
  // Both emitters that stamped peer_id were fixed to the canonical key
  // (5bfdb206, 80a8ec08), and a census of system_fleet_events (29,382,053 rows,
  // 2026-08-26) found 0 rows carrying platform_peer_id and 497 carrying
  // peer_id — every one of them an Sdwan::Peer id under kind
  // sdwan.credential_issued / system.sdwan_credential_expiring, i.e. a
  // DIFFERENT MODEL that the kind filter below already excludes. Reading them
  // here could only ever have matched by UUID collision.
  // We bump last_heartbeat_at on any matching event and flag the row "live".
  useEffect(() => {
    if (!isConnected || !accountId) return;

    const unsub = subscribe({
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (raw: unknown) => {
        const evt = raw as
          | (Record<string, unknown> & {
              type?: string;
              kind?: string;
              payload?: Record<string, unknown>;
              emitted_at?: string;
            })
          | null;
        if (!evt || evt.type === 'connection_established' || evt.type === 'pong') return;
        const kind = typeof evt.kind === 'string' ? evt.kind : '';
        // Only react to federation-relevant kinds to avoid churn on the
        // (high-volume) general fleet stream.
        if (!kind.includes('federation') && !kind.includes('platform_peer') && !kind.includes('peer')) {
          return;
        }
        const payload = (evt.payload ?? {}) as Record<string, unknown>;
        const peerId =
          (typeof payload.federation_peer_id === 'string' && payload.federation_peer_id) || null;
        const remoteUrl =
          typeof payload.remote_instance_url === 'string' ? payload.remote_instance_url : null;
        const emittedAt = typeof evt.emitted_at === 'string' ? evt.emitted_at : new Date().toISOString();
        const nextStatus = typeof payload.status === 'string' ? (payload.status as PeerStatus) : null;

        setPeers((prev) => {
          let matched: string | null = null;
          const next = prev.map((p) => {
            const isMatch = (peerId && p.id === peerId) || (remoteUrl && p.remote_instance_url === remoteUrl);
            if (!isMatch) return p;
            matched = p.id;
            return {
              ...p,
              last_heartbeat_at: emittedAt,
              status: nextStatus ?? p.status,
            };
          });
          if (matched) {
            setLivePeerIds((live) => {
              const updated = new Set(live);
              updated.add(matched as string);
              return updated;
            });
          }
          return next;
        });
      },
      onError: (err: string) => logger.warn('[PeerLivenessMonitor] SystemFleetChannel error', { err }),
    });

    return () => {
      if (unsub) unsub();
    };
  }, [isConnected, accountId, subscribe, setPeers]);

  const summary = useMemo(() => {
    const active = peers.filter((p) => p.status === 'active').length;
    const degraded = peers.filter((p) => p.status === 'degraded' || p.status === 'suspended').length;
    const stale = peers.filter((p) => {
      if (!p.last_heartbeat_at) return p.status === 'active' || p.status === 'enrolled';
      return Date.now() - new Date(p.last_heartbeat_at).getTime() > HEARTBEAT_STALE_MS;
    }).length;
    return { active, degraded, stale, total: peers.length };
  }, [peers]);

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden" data-testid="peer-liveness-monitor">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Network className="w-5 h-5 text-theme-info-fg" />
          <h2 className="font-semibold text-theme-primary">Peer Liveness</h2>
          <span className="text-xs text-theme-secondary">
            {loading ? 'loading…' : `${summary.total} ${summary.total === 1 ? 'peer' : 'peers'}`}
          </span>
        </div>
        <div className="flex items-center gap-3">
          <span
            className="inline-flex items-center gap-1 text-xs text-theme-secondary"
            title={isConnected ? 'Live channel connected' : 'Live channel offline — showing last-known state'}
          >
            {isConnected ? (
              <Wifi className="w-3.5 h-3.5 text-theme-success-fg" />
            ) : (
              <WifiOff className="w-3.5 h-3.5 text-theme-warning-fg" />
            )}
            {isConnected ? 'live' : 'offline'}
          </span>
          <button
            type="button"
            onClick={() => void refetch()}
            disabled={loading}
            title="Refresh"
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          </button>
        </div>
      </header>

      <div className="px-4 py-2 border-b border-theme flex items-center gap-4 text-xs">
        <span className="text-theme-secondary">
          active <span className="font-mono text-theme-success-fg">{summary.active}</span>
        </span>
        <span className="text-theme-secondary">
          degraded <span className="font-mono text-theme-warning-fg">{summary.degraded}</span>
        </span>
        <span className="text-theme-secondary">
          stale heartbeat <span className="font-mono text-theme-primary">{summary.stale}</span>
        </span>
      </div>

      {error && (
        <div className="p-3 bg-theme-danger-bg text-theme-danger-fg flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
        </div>
      )}

      {!loading && peers.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No federation peers yet. Use the Control tab to propose one.
        </div>
      )}

      {peers.length > 0 && (
        <PeerTable
          columns={[
            { label: 'Remote URL' },
            { label: 'Status' },
            { label: 'Endpoints' },
            { label: 'Last Heartbeat' },
          ]}
        >
          {peers.map((peer) => (
            <LivenessRow
              key={peer.id}
              peer={peer}
              isLive={livePeerIds.has(peer.id)}
              onSelect={() => setSelectedId(peer.id)}
            />
          ))}
        </PeerTable>
      )}

      <PeerDetailDrawer peerId={selectedId} onClose={() => setSelectedId(null)} />
    </div>
  );
};

interface LivenessRowProps {
  peer: PlatformPeerSummary;
  isLive: boolean;
  onSelect: () => void;
}

const LivenessRow: React.FC<LivenessRowProps> = ({ peer, isLive, onSelect }) => {
  const heartbeatMs = peer.last_heartbeat_at ? new Date(peer.last_heartbeat_at).getTime() : null;
  const isStale =
    heartbeatMs === null
      ? peer.status === 'active' || peer.status === 'enrolled'
      : Date.now() - heartbeatMs > HEARTBEAT_STALE_MS;

  return (
    <tr
      className="border-t border-theme cursor-pointer hover:bg-theme-surface-hover transition-colors"
      onClick={onSelect}
      data-testid={`liveness-row-${peer.id}`}
    >
      <PeerUrlCell peer={peer} live={isLive} />
      <PeerStatusCell peer={peer} />
      <td className="px-4 py-3 text-xs text-theme-secondary">{peer.endpoints_count}</td>
      <PeerHeartbeatCell peer={peer} stale={isStale} />
    </tr>
  );
};

export default PeerLivenessMonitor;
