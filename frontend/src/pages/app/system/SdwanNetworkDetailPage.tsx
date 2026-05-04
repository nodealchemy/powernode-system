import React, { useEffect, useState, useCallback } from 'react';
import { useParams } from 'react-router-dom';
import { Plus, Pencil } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
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
} from '@system/features/system/components/sdwan';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type { SdwanNetwork, SdwanPeer, SdwanFirewallRule } from '@system/features/system/types/sdwan.types';

type TabKey = 'topology' | 'peers' | 'firewall' | 'access' | 'vips' | 'routing' | 'port_mappings';

const SdwanNetworkDetailPage: React.FC = () => {
  const { id } = useParams<{ id: string }>();
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();

  const canManageNetwork = hasPermission('sdwan.networks.manage');
  const canManagePeers = hasPermission('sdwan.peers.manage');
  const canManageFw = hasPermission('sdwan.firewall.manage');
  const canManageVips = hasPermission('sdwan.vips.manage');
  const canManageRouting = hasPermission('sdwan.routing.manage');
  const canManagePortMappings = hasPermission('sdwan.port_mappings.manage');

  const [network, setNetwork] = useState<SdwanNetwork | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<TabKey>('topology');
  const [refreshKey, setRefreshKey] = useState(0);

  const [showAttachPeer, setShowAttachPeer] = useState(false);
  const [showAddRule, setShowAddRule] = useState(false);
  const [showEditNetwork, setShowEditNetwork] = useState(false);
  const [peerToDetach, setPeerToDetach] = useState<SdwanPeer | null>(null);
  const [peerToEdit, setPeerToEdit] = useState<SdwanPeer | null>(null);
  const [ruleToDelete, setRuleToDelete] = useState<SdwanFirewallRule | null>(null);
  const [ruleToEdit, setRuleToEdit] = useState<SdwanFirewallRule | null>(null);

  // Slice 9d2 — tab-orchestrators publish action handles on mount so
  // the page can wire them into PageContainer.actions. Per-tab refs
  // because an action is meaningful only when its tab is active.
  const [vipActions, setVipActions] = useState<{ openCreate: () => void } | null>(null);
  const [routingActions, setRoutingActions] = useState<{ openModeToggle: () => void } | null>(null);
  const [portMappingActions, setPortMappingActions] = useState<{ openCreate: () => void } | null>(null);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  const loadNetwork = useCallback(async () => {
    if (!id) return;
    try {
      setLoading(true);
      setError(null);
      const n = await sdwanApi.getNetwork(id);
      setNetwork(n);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load network');
    } finally {
      setLoading(false);
    }
  }, [id]);

  useEffect(() => { loadNetwork(); }, [loadNetwork, refreshKey]);

  const handleConfirmDetach = useCallback(async () => {
    if (!peerToDetach || !id) return;
    try {
      await sdwanApi.detachPeer(id, peerToDetach.id);
      addNotification({ type: 'success', message: 'Peer detached' });
      setPeerToDetach(null);
      triggerRefresh();
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to detach peer',
      });
    }
  }, [peerToDetach, id, addNotification, triggerRefresh]);

  const handleConfirmDeleteRule = useCallback(async () => {
    if (!ruleToDelete || !id) return;
    try {
      await sdwanApi.deleteFirewallRule(id, ruleToDelete.id);
      addNotification({ type: 'success', message: `Rule "${ruleToDelete.name}" deleted` });
      setRuleToDelete(null);
      triggerRefresh();
    } catch (err) {
      addNotification({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete rule',
      });
    }
  }, [ruleToDelete, id, addNotification, triggerRefresh]);

  if (loading && !network) return <div className="p-8 text-theme-secondary">Loading network…</div>;
  if (error) return <div className="p-4 bg-theme-danger text-theme-danger rounded">{error}</div>;
  if (!network) return null;

  const tabActions = (() => {
    const actions: { label: string; onClick: () => void; variant: 'primary' | 'secondary'; icon: typeof Plus }[] = [];
    if (canManageNetwork) {
      actions.push({ label: 'Edit network', onClick: () => setShowEditNetwork(true), variant: 'secondary', icon: Pencil });
    }
    if (tab === 'peers' && canManagePeers) {
      actions.push({ label: 'Attach peer', onClick: () => setShowAttachPeer(true), variant: 'primary', icon: Plus });
    }
    if (tab === 'firewall' && canManageFw) {
      actions.push({ label: 'Add rule', onClick: () => setShowAddRule(true), variant: 'primary', icon: Plus });
    }
    // Slice 9d2 — wire tab orchestrators' published action handles into
    // PageContainer.actions. The handle is only set when the matching
    // tab is mounted, so guarding on the handle's presence implicitly
    // gates by tab.
    if (tab === 'vips' && canManageVips && vipActions) {
      actions.push({ label: 'New VIP', onClick: vipActions.openCreate, variant: 'primary', icon: Plus });
    }
    if (tab === 'routing' && canManageRouting && routingActions) {
      actions.push({ label: 'Change routing mode', onClick: routingActions.openModeToggle, variant: 'secondary', icon: Pencil });
    }
    if (tab === 'port_mappings' && canManagePortMappings && portMappingActions) {
      actions.push({ label: 'New port mapping', onClick: portMappingActions.openCreate, variant: 'primary', icon: Plus });
    }
    return actions;
  })();

  return (
    <PageContainer
      title={network.name}
      description={`${network.cidr_64} · ${network.peer_count} peer${network.peer_count === 1 ? '' : 's'} · status: ${network.status}`}
      breadcrumbs={[
        { label: 'System', href: '/app/system' },
        { label: 'SDWAN', href: '/app/system/sdwan' },
        { label: network.name },
      ]}
      actions={tabActions}
    >
      <div className="border-b border-theme-border mb-4">
        <nav className="flex gap-4">
          {(['topology', 'peers', 'firewall', 'access', 'vips', 'routing', 'port_mappings'] as TabKey[]).map((k) => (
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
              {k === 'port_mappings' ? 'Port mappings' : k.charAt(0).toUpperCase() + k.slice(1)}
            </button>
          ))}
        </nav>
      </div>

      {tab === 'topology' && <SdwanTopology networkId={network.id} refreshKey={refreshKey} />}
      {tab === 'peers' && (
        <PeerList
          networkId={network.id}
          onDetach={canManagePeers ? setPeerToDetach : undefined}
          onEdit={canManagePeers ? setPeerToEdit : undefined}
          refreshKey={refreshKey}
        />
      )}
      {tab === 'firewall' && (
        <FirewallRuleList
          networkId={network.id}
          onDelete={canManageFw ? setRuleToDelete : undefined}
          onEdit={canManageFw ? setRuleToEdit : undefined}
          refreshKey={refreshKey}
        />
      )}
      {tab === 'access' && (
        <AccessTab networkId={network.id} refreshKey={refreshKey} />
      )}
      {tab === 'vips' && <NetworkVipsTab networkId={network.id} onActionsReady={setVipActions} />}
      {tab === 'routing' && (
        <NetworkRoutingTab network={network} onNetworkUpdated={setNetwork} onActionsReady={setRoutingActions} />
      )}
      {tab === 'port_mappings' && (
        <NetworkPortMappingsTab networkId={network.id} onActionsReady={setPortMappingActions} />
      )}

      <PeerAttachModal
        isOpen={showAttachPeer}
        networkId={network.id}
        onClose={() => setShowAttachPeer(false)}
        onAttached={triggerRefresh}
      />

      <PeerEditModal
        isOpen={peerToEdit !== null}
        networkId={network.id}
        peer={peerToEdit}
        onClose={() => setPeerToEdit(null)}
        onSaved={triggerRefresh}
      />

      <FirewallRuleCreateModal
        isOpen={showAddRule}
        networkId={network.id}
        onClose={() => setShowAddRule(false)}
        onCreated={triggerRefresh}
      />

      <FirewallRuleEditModal
        isOpen={ruleToEdit !== null}
        networkId={network.id}
        rule={ruleToEdit}
        onClose={() => setRuleToEdit(null)}
        onSaved={triggerRefresh}
      />

      <NetworkEditModal
        isOpen={showEditNetwork}
        network={network}
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
              The peer's keypair is revoked; the agent will tear down the interface on its next heartbeat.
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
    </PageContainer>
  );
};

export default SdwanNetworkDetailPage;
