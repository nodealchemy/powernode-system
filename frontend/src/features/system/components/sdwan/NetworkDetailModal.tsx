import React, { useEffect, useState, useCallback } from 'react';
import { Plus, Pencil } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import {
  PeerList,
  PeerAttachModal,
  PeerEditModal,
  FirewallRuleList,
  FirewallRuleCreateModal,
  FirewallRuleEditModal,
  SdwanTopology,
  NetworkEditModal,
  AccessTab,
  NetworkVipsTab,
  NetworkRoutingTab,
  NetworkPortMappingsTab,
} from '../../components/sdwan';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanNetwork,
  SdwanPeer,
  SdwanFirewallRule,
} from '../../types/sdwan.types';

interface NetworkDetailModalProps {
  network: SdwanNetwork | null;
  isOpen: boolean;
  onClose: () => void;
}

type TabKey = 'topology' | 'peers' | 'firewall' | 'access' | 'vips' | 'routing' | 'port_mappings';

const TAB_LABELS: Record<TabKey, string> = {
  topology: 'Topology',
  peers: 'Peers',
  firewall: 'Firewall',
  access: 'Access',
  vips: 'VIPs',
  routing: 'Routing',
  port_mappings: 'Port mappings',
};

/**
 * NetworkDetailModal — full SDWAN network management surface as a
 * modal (replaces the prior standalone /app/system/sdwan/networks/:id
 * page). Hosts the same 7 tabs the page did:
 *
 *   topology · peers · firewall · access · vips · routing · port_mappings
 *
 * Per-tab action buttons render in the modal header (mirrors the page's
 * PageContainer.actions pattern). Nested modals (PeerAttachModal,
 * FirewallRuleCreateModal, PeerEditModal, etc.) stack on top via the
 * Modal component's portal — z-index handled by the portal layer.
 *
 * Direct URL access at /app/system/sdwan/networks/:id is preserved by
 * SdwanNetworkDetailPage, which is now a thin wrapper that renders
 * this modal in `isOpen` state with a close handler that navigates to
 * the networks list. List-row interaction in NetworksTab opens the
 * modal directly without changing routes.
 */
export const NetworkDetailModal: React.FC<NetworkDetailModalProps> = ({
  network,
  isOpen,
  onClose,
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  const canManageNetwork      = hasPermission('sdwan.networks.manage');
  const canManagePeers        = hasPermission('sdwan.peers.manage');
  const canManageFw           = hasPermission('sdwan.firewall.manage');
  const canManageVips         = hasPermission('sdwan.vips.manage');
  const canManageRouting      = hasPermission('sdwan.routing.manage');
  const canManagePortMappings = hasPermission('sdwan.port_mappings.manage');

  // Local network detail — refetched on open + on triggerRefresh so
  // we always show the freshest data without forcing parent rerender.
  const [detail, setDetail] = useState<SdwanNetwork | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<TabKey>('topology');
  const [refreshKey, setRefreshKey] = useState(0);

  const [showAttachPeer, setShowAttachPeer]     = useState(false);
  const [showAddRule, setShowAddRule]           = useState(false);
  const [showEditNetwork, setShowEditNetwork]   = useState(false);
  const [peerToDetach, setPeerToDetach]         = useState<SdwanPeer | null>(null);
  const [peerToEdit, setPeerToEdit]             = useState<SdwanPeer | null>(null);
  const [ruleToDelete, setRuleToDelete]         = useState<SdwanFirewallRule | null>(null);
  const [ruleToEdit, setRuleToEdit]             = useState<SdwanFirewallRule | null>(null);

  // Per-tab action handles published by orchestrator tabs (slice 9d2
  // pattern) — VIPs/Routing/Port mappings publish openCreate-style
  // callbacks the parent renders into the action area. Per-tab refs
  // because an action is meaningful only when its tab is active.
  const [vipActions, setVipActions]                 = useState<{ openCreate: () => void } | null>(null);
  const [routingActions, setRoutingActions]         = useState<{ openModeToggle: () => void } | null>(null);
  const [portMappingActions, setPortMappingActions] = useState<{ openCreate: () => void } | null>(null);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  const loadNetwork = useCallback(async (id: string) => {
    try {
      setLoading(true);
      setError(null);
      const n = await sdwanApi.getNetwork(id);
      setDetail(n);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load network');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (isOpen && network) {
      loadNetwork(network.id);
    } else if (!isOpen) {
      // Clear stale state when the modal closes so a future open
      // doesn't briefly flash the previous network's data.
      setDetail(null);
      setError(null);
      setTab('topology');
      setShowAttachPeer(false);
      setShowAddRule(false);
      setShowEditNetwork(false);
      setPeerToDetach(null);
      setPeerToEdit(null);
      setRuleToDelete(null);
      setRuleToEdit(null);
    }
  }, [isOpen, network, loadNetwork, refreshKey]);

  const handleConfirmDetach = useCallback(async () => {
    if (!peerToDetach || !detail) return;
    try {
      await sdwanApi.detachPeer(detail.id, peerToDetach.id);
      addNotification({ type: 'success', message: 'Peer detached' });
      setPeerToDetach(null);
      triggerRefresh();
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to detach peer',
      });
    }
  }, [peerToDetach, detail, addNotification, triggerRefresh]);

  const handleConfirmDeleteRule = useCallback(async () => {
    if (!ruleToDelete || !detail) return;
    try {
      await sdwanApi.deleteFirewallRule(detail.id, ruleToDelete.id);
      addNotification({ type: 'success', message: `Rule "${ruleToDelete.name}" deleted` });
      setRuleToDelete(null);
      triggerRefresh();
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete rule',
      });
    }
  }, [ruleToDelete, detail, addNotification, triggerRefresh]);

  if (!network) return null;
  const display = detail ?? network;

  const subtitle = `${display.cidr_64} · ${display.peer_count} peer${display.peer_count === 1 ? '' : 's'} · ${display.status}`;

  const tabActions: { label: string; onClick: () => void; variant: 'primary' | 'secondary'; icon: typeof Plus }[] = [];
  if (canManageNetwork) {
    tabActions.push({ label: 'Edit network', onClick: () => setShowEditNetwork(true), variant: 'secondary', icon: Pencil });
  }
  if (tab === 'peers' && canManagePeers) {
    tabActions.push({ label: 'Attach peer', onClick: () => setShowAttachPeer(true), variant: 'primary', icon: Plus });
  }
  if (tab === 'firewall' && canManageFw) {
    tabActions.push({ label: 'Add rule', onClick: () => setShowAddRule(true), variant: 'primary', icon: Plus });
  }
  if (tab === 'vips' && canManageVips && vipActions) {
    tabActions.push({ label: 'New VIP', onClick: vipActions.openCreate, variant: 'primary', icon: Plus });
  }
  if (tab === 'routing' && canManageRouting && routingActions) {
    tabActions.push({ label: 'Change routing mode', onClick: routingActions.openModeToggle, variant: 'secondary', icon: Pencil });
  }
  if (tab === 'port_mappings' && canManagePortMappings && portMappingActions) {
    tabActions.push({ label: 'New port mapping', onClick: portMappingActions.openCreate, variant: 'primary', icon: Plus });
  }

  return (
    <>
      <Modal
        isOpen={isOpen}
        onClose={onClose}
        title={display.name}
        subtitle={subtitle}
        size="7xl"
      >
        <div className="space-y-4 min-h-[60vh]">
          {/* Per-tab action row */}
          {tabActions.length > 0 && (
            <div className="flex items-center justify-end gap-2">
              {tabActions.map((a) => (
                <Button key={a.label} variant={a.variant} onClick={a.onClick} size="sm">
                  <a.icon size={16} className="mr-1" />
                  {a.label}
                </Button>
              ))}
            </div>
          )}

          {/* Tab nav */}
          <div className="border-b border-theme-border">
            <nav className="flex gap-4 flex-wrap">
              {(Object.keys(TAB_LABELS) as TabKey[]).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => setTab(k)}
                  className={
                    'px-3 py-2 text-sm font-medium border-b-2 transition-colors ' +
                    (tab === k
                      ? 'border-theme-accent text-theme-accent'
                      : 'border-transparent text-theme-secondary hover:text-theme-primary')
                  }
                >
                  {TAB_LABELS[k]}
                </button>
              ))}
            </nav>
          </div>

          {/* Loading / error overlay for the underlying detail fetch */}
          {loading && !detail && (
            <div className="p-8 text-center text-theme-secondary">Loading network…</div>
          )}
          {error && (
            <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>
          )}

          {/* Tab content */}
          {!loading && !error && (
            <div>
              {tab === 'topology' && (
                <SdwanTopology networkId={display.id} refreshKey={refreshKey} />
              )}
              {tab === 'peers' && (
                <PeerList
                  networkId={display.id}
                  onDetach={canManagePeers ? setPeerToDetach : undefined}
                  onEdit={canManagePeers ? setPeerToEdit : undefined}
                  refreshKey={refreshKey}
                />
              )}
              {tab === 'firewall' && (
                <FirewallRuleList
                  networkId={display.id}
                  onDelete={canManageFw ? setRuleToDelete : undefined}
                  onEdit={canManageFw ? setRuleToEdit : undefined}
                  refreshKey={refreshKey}
                />
              )}
              {tab === 'access' && (
                <AccessTab networkId={display.id} refreshKey={refreshKey} />
              )}
              {tab === 'vips' && (
                <NetworkVipsTab networkId={display.id} onActionsReady={setVipActions} />
              )}
              {tab === 'routing' && (
                <NetworkRoutingTab
                  network={display}
                  onNetworkUpdated={(updated) => setDetail(updated)}
                  onActionsReady={setRoutingActions}
                />
              )}
              {tab === 'port_mappings' && (
                <NetworkPortMappingsTab networkId={display.id} onActionsReady={setPortMappingActions} />
              )}
            </div>
          )}
        </div>
      </Modal>

      {/* Stacked modals — render outside the parent Modal because they
          use their own portals + z-index. The Modal component handles
          stacking automatically via createPortal. */}
      <PeerAttachModal
        isOpen={showAttachPeer}
        networkId={display.id}
        onClose={() => setShowAttachPeer(false)}
        onAttached={triggerRefresh}
      />

      <PeerEditModal
        isOpen={peerToEdit !== null}
        networkId={display.id}
        peer={peerToEdit}
        onClose={() => setPeerToEdit(null)}
        onSaved={triggerRefresh}
      />

      <FirewallRuleCreateModal
        isOpen={showAddRule}
        networkId={display.id}
        onClose={() => setShowAddRule(false)}
        onCreated={triggerRefresh}
      />

      <FirewallRuleEditModal
        isOpen={ruleToEdit !== null}
        networkId={display.id}
        rule={ruleToEdit}
        onClose={() => setRuleToEdit(null)}
        onSaved={triggerRefresh}
      />

      <NetworkEditModal
        isOpen={showEditNetwork}
        network={display}
        onClose={() => setShowEditNetwork(false)}
        onSaved={triggerRefresh}
      />

      <Modal isOpen={peerToDetach !== null} onClose={() => setPeerToDetach(null)} title="Detach peer">
        {peerToDetach && (
          <div className="space-y-4">
            <p className="text-theme-primary">
              Detach peer at <span className="font-mono">{peerToDetach.assigned_address}</span>?
            </p>
            <p className="text-sm text-theme-secondary">
              The peer&apos;s keypair is revoked; the agent will tear down the interface on its next heartbeat.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setPeerToDetach(null)}>Cancel</Button>
              <Button variant="danger" onClick={handleConfirmDetach}>Detach</Button>
            </div>
          </div>
        )}
      </Modal>

      <Modal isOpen={ruleToDelete !== null} onClose={() => setRuleToDelete(null)} title="Delete firewall rule">
        {ruleToDelete && (
          <div className="space-y-4">
            <p className="text-theme-primary">
              Delete rule <strong>{ruleToDelete.name}</strong>?
            </p>
            <p className="text-sm text-theme-secondary">
              The rule disappears from the next agent reconcile (one heartbeat tick).
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setRuleToDelete(null)}>Cancel</Button>
              <Button variant="danger" onClick={handleConfirmDeleteRule}>Delete</Button>
            </div>
          </div>
        )}
      </Modal>
    </>
  );
};
