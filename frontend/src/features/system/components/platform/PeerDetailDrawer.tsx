import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  X,
  Network,
  AlertTriangle,
  ExternalLink,
  ShieldCheck,
  Globe2,
  GitBranch,
} from 'lucide-react';
import { platformPeersApi } from '../../services/api/platformPeersApi';
import type { PlatformPeerDetail, PeerEndpoint } from '../../types/peer.types';
import { GrantsManagementModal } from './GrantsManagementModal';
import { CapabilitiesManagementModal } from './CapabilitiesManagementModal';

/**
 * Slide-out drawer showing the full federation peer detail: endpoints
 * with health, capabilities snapshot, and related-record counts that
 * link off to dedicated panels (grants editor, capabilities editor,
 * SDWAN bridge view).
 *
 * Plan reference: Decentralized Federation §I + P7.1.
 */

interface PeerDetailDrawerProps {
  peerId: string | null;
  onClose: () => void;
}

export const PeerDetailDrawer: React.FC<PeerDetailDrawerProps> = ({ peerId, onClose }) => {
  const [peer, setPeer] = useState<PlatformPeerDetail | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [grantsOpen, setGrantsOpen] = useState(false);
  const [capabilitiesOpen, setCapabilitiesOpen] = useState(false);

  useEffect(() => {
    if (!peerId) {
      setPeer(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    platformPeersApi
      .getPeer(peerId)
      .then((p) => {
        if (!cancelled) setPeer(p);
      })
      .catch((err: unknown) => {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Failed to load peer');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [peerId]);

  if (!peerId) return null;

  return (
    <>
      <div
        className="fixed inset-0 bg-black/40 z-30"
        onClick={onClose}
        aria-hidden="true"
      />
      <aside className="fixed top-0 right-0 h-full w-full max-w-lg bg-theme-surface border-l border-theme z-40 shadow-lg overflow-y-auto">
        <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3 sticky top-0 bg-theme-surface">
          <div className="flex items-center gap-2">
            <Network className="w-5 h-5 text-theme-info" />
            <h3 className="font-semibold text-theme-primary">Peer Detail</h3>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors"
          >
            <X className="w-4 h-4" />
          </button>
        </header>

        {error && (
          <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
            <AlertTriangle className="w-4 h-4 flex-shrink-0" />
            <span className="flex-1">{error}</span>
          </div>
        )}

        {loading && <div className="p-6 text-sm text-theme-secondary">Loading…</div>}

        {peer && (
          <div className="p-4 space-y-5">
            <section>
              <div className="text-xs text-theme-tertiary uppercase mb-1">Remote URL</div>
              <div className="font-mono text-sm text-theme-primary break-all">
                {peer.remote_instance_url}
              </div>
            </section>

            <section className="grid grid-cols-2 gap-3">
              <KeyValue label="Status" value={peer.status} mono />
              <KeyValue label="Peer Kind" value={peer.peer_kind} mono />
              <KeyValue label="Role" value={peer.spawn_role ?? '—'} mono />
              <KeyValue label="Mode" value={peer.spawn_mode ?? '—'} mono />
              <KeyValue
                label="Contract Version"
                value={peer.contract_version_agreed ?? '—'}
                mono
              />
              <KeyValue
                label="Last Heartbeat"
                value={peer.last_heartbeat_at
                  ? new Date(peer.last_heartbeat_at).toLocaleString()
                  : 'never'}
              />
            </section>

            {peer.acceptance_pending && peer.acceptance_expires_at && (
              <section className="p-3 bg-theme-warning text-theme-warning text-xs rounded">
                <strong>Acceptance pending</strong> — token expires{' '}
                {new Date(peer.acceptance_expires_at).toLocaleString()}. The
                remote operator must POST the token to{' '}
                <code className="font-mono">/federation_api/accept</code> before
                this peer can transition to <code className="font-mono">accepted</code>.
              </section>
            )}

            <section>
              <div className="text-xs text-theme-tertiary uppercase mb-2">
                Endpoints ({peer.endpoints.length})
              </div>
              {peer.endpoints.length === 0 ? (
                <div className="text-sm text-theme-secondary">No endpoints declared.</div>
              ) : (
                <div className="space-y-2">
                  {[...peer.endpoints]
                    .sort((a, b) => a.priority - b.priority)
                    .map((ep, idx) => (
                      <EndpointCard key={idx} endpoint={ep} />
                    ))}
                </div>
              )}
            </section>

            <section>
              <div className="text-xs text-theme-tertiary uppercase mb-2">Allowed Transitions</div>
              {peer.allowed_transitions.length === 0 ? (
                <div className="text-sm text-theme-tertiary italic">
                  Terminal — no further transitions.
                </div>
              ) : (
                <div className="flex flex-wrap gap-1">
                  {peer.allowed_transitions.map((t) => (
                    <span
                      key={t}
                      className="px-2 py-0.5 bg-theme-background-secondary rounded text-xs font-mono text-theme-secondary"
                    >
                      → {t}
                    </span>
                  ))}
                </div>
              )}
            </section>

            <section>
              <div className="text-xs text-theme-tertiary uppercase mb-2">Related Records</div>
              <div className="grid grid-cols-3 gap-2">
                <RelatedCard
                  icon={<ShieldCheck className="w-4 h-4 text-theme-info" />}
                  label="Grants"
                  count={peer.grants_count}
                  onClick={() => setGrantsOpen(true)}
                />
                <RelatedCard
                  icon={<Globe2 className="w-4 h-4 text-theme-info" />}
                  label="Capabilities"
                  count={peer.capabilities_count}
                  onClick={() => setCapabilitiesOpen(true)}
                />
                <RelatedCard
                  icon={<GitBranch className="w-4 h-4 text-theme-info" />}
                  label="Bridges"
                  count={peer.bridges_count}
                  linkTo="/app/system/sdwan/topology"
                />
              </div>
              <p className="text-xs text-theme-secondary mt-2">
                Click "Grants" to issue or revoke per-resource access. "Capabilities"
                opens the per-pair sync policy editor. Bridges are visible in the
                SDWAN topology view.
              </p>
            </section>

            {peer.extension_slugs.length > 0 && (
              <section>
                <div className="text-xs text-theme-tertiary uppercase mb-2">Remote Extensions</div>
                <div className="flex flex-wrap gap-1">
                  {peer.extension_slugs.map((slug) => (
                    <span
                      key={slug}
                      className="px-2 py-0.5 bg-theme-background-secondary rounded text-xs font-mono text-theme-secondary"
                    >
                      {slug}
                    </span>
                  ))}
                </div>
              </section>
            )}

            {Object.keys(peer.capabilities).length > 0 && (
              <section>
                <div className="text-xs text-theme-tertiary uppercase mb-2">
                  Capabilities Snapshot
                </div>
                <pre className="text-xs bg-theme-background-secondary p-2 rounded overflow-x-auto font-mono text-theme-primary max-h-40">
                  {JSON.stringify(peer.capabilities, null, 2)}
                </pre>
              </section>
            )}

            {Object.keys(peer.metadata).length > 0 && (
              <section>
                <div className="text-xs text-theme-tertiary uppercase mb-2">Metadata</div>
                <pre className="text-xs bg-theme-background-secondary p-2 rounded overflow-x-auto font-mono text-theme-primary max-h-40">
                  {JSON.stringify(peer.metadata, null, 2)}
                </pre>
              </section>
            )}
          </div>
        )}
      </aside>

      <GrantsManagementModal
        isOpen={grantsOpen}
        peerId={peer?.id ?? null}
        peerLabel={peer?.remote_instance_url ?? ''}
        onClose={() => setGrantsOpen(false)}
      />

      <CapabilitiesManagementModal
        isOpen={capabilitiesOpen}
        peerId={peer?.id ?? null}
        peerLabel={peer?.remote_instance_url ?? ''}
        onClose={() => setCapabilitiesOpen(false)}
      />
    </>
  );
};

const KeyValue: React.FC<{ label: string; value: string; mono?: boolean }> = ({
  label,
  value,
  mono,
}) => (
  <div>
    <div className="text-xs text-theme-tertiary uppercase mb-0.5">{label}</div>
    <div className={`text-sm text-theme-primary ${mono ? 'font-mono' : ''}`}>{value}</div>
  </div>
);

const EndpointCard: React.FC<{ endpoint: PeerEndpoint }> = ({ endpoint }) => {
  const statusColor =
    endpoint.status === 'reachable'
      ? 'text-theme-success'
      : endpoint.status === 'unreachable'
        ? 'text-theme-danger'
        : 'text-theme-secondary';

  return (
    <div className="p-2 bg-theme-background-secondary border border-theme rounded text-xs">
      <div className="flex items-center justify-between gap-2 mb-1">
        <span className="font-mono text-theme-primary break-all">{endpoint.url}</span>
        <span className="px-1.5 py-0.5 bg-theme-surface rounded text-theme-secondary font-mono">
          {endpoint.scope}
        </span>
      </div>
      <div className="flex items-center justify-between text-theme-secondary">
        <span>
          priority <span className="font-mono text-theme-primary">{endpoint.priority}</span>
        </span>
        {endpoint.status && (
          <span className={`font-mono ${statusColor}`}>
            {endpoint.status}
          </span>
        )}
      </div>
      {endpoint.last_verified_at && (
        <div className="text-theme-tertiary mt-1">
          verified {new Date(endpoint.last_verified_at).toLocaleString()}
        </div>
      )}
    </div>
  );
};

const RelatedCard: React.FC<{
  icon: React.ReactNode;
  label: string;
  count: number;
  linkTo?: string;
  onClick?: () => void;
}> = ({ icon, label, count, linkTo, onClick }) => {
  const interactive = Boolean(linkTo || onClick);
  const body = (
    <div className={`p-2 bg-theme-background-secondary border border-theme rounded text-center transition-colors ${
      interactive ? 'hover:bg-theme-surface-hover cursor-pointer' : ''
    }`}>
      <div className="flex items-center justify-center gap-1 text-xs text-theme-secondary mb-0.5">
        {icon}
        <span>{label}</span>
        {linkTo && <ExternalLink className="w-3 h-3" />}
      </div>
      <div className="text-lg font-semibold text-theme-primary">{count}</div>
    </div>
  );

  if (linkTo) return <Link to={linkTo}>{body}</Link>;
  if (onClick) {
    return (
      <button type="button" onClick={onClick} className="w-full text-left">
        {body}
      </button>
    );
  }
  return body;
};
