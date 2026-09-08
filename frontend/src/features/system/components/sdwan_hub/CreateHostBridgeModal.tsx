import React, { useEffect, useState } from 'react';
import { Network as NetworkIcon } from 'lucide-react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import { apiErrorMessage, isPendingApproval } from '@system/features/system/services/api/helpers';
import { pendingApprovalNotice } from '@system/features/system/utils/pendingApproval';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeInstance } from '@system/features/system/types/system.types';
import type { SdwanHostBridgeKind } from '@system/features/system/types/sdwan.types';

// One page of nodes; the instance lists are then fetched per node. Surfaced as
// a constant so the warning below and the request cannot drift apart.
const HOST_PAGE_SIZE = 50;

interface CreateHostBridgeModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated: () => void;
}

/**
 * Allocate an SDWAN host bridge on a chosen host (IMP-61be0ada331d).
 *
 * A bridge is scoped to a HOST, not to a network: POST
 * /system/sdwan/host_bridges reads node_instance_id and an optional kind, and
 * nothing else. Sdwan::HostBridgeAllocator mints the short_id under a per-host
 * row lock, which is why there is no name or id field here to fill in.
 *
 * `kind` defaults to "let the allocator decide" rather than to a value: the
 * allocator resolves it from the host's network_profile (heavyweight → ovs,
 * lightweight → linux), and picking a default in the form is how two surfaces
 * start answering one payload differently. The override stays available because
 * the API accepts one.
 *
 * Creation is gated through Sdwan::Executors::CreateHostBridge, so a seeded
 * account can park it for approval — the caller must branch on
 * isPendingApproval rather than reporting a bridge that does not exist yet.
 *
 * "Allocate" is also IDEMPOTENT AND READOPTING, which is why the result copy
 * names the state the server came back with rather than asserting one.
 * Sdwan::HostBridgeAllocator returns the host's existing bridge of the resolved
 * kind if there is one, and a `removed` row is readopted straight to ACTIVE —
 * so this form is also the console's only revive path. Claiming "starts in
 * pending, activate it next" would be the exact inverse of what happened in
 * that case, and it is what the MCP twin's own description warns about.
 */
export const CreateHostBridgeModal: React.FC<CreateHostBridgeModalProps> = ({
  isOpen,
  onClose,
  onCreated,
}) => {
  const { addNotification } = useNotifications();
  const [instances, setInstances] = useState<SystemNodeInstance[]>([]);
  const [loadingInstances, setLoadingInstances] = useState(false);
  const [nodeInstanceId, setNodeInstanceId] = useState('');
  const [kind, setKind] = useState<SdwanHostBridgeKind | ''>('');
  const [truncated, setTruncated] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!isOpen) return;
    setLoadingInstances(true);
    // /system/nodes nests instances under each node, so a flat host list means
    // walking nodes then their instances — the same route PeerAttachModal takes.
    setTruncated(false);
    systemApi
      .getNodes({ per_page: HOST_PAGE_SIZE })
      .then(async ({ nodes, meta }) => {
        const instLists = await Promise.all(
          nodes.map((n) => systemApi.getNodeInstances(n.id).then((r) => r.node_instances)),
        );
        setInstances(instLists.flat());
        // One page only. Silently omitting hosts would reopen the very gap this
        // form exists to close, just above HOST_PAGE_SIZE nodes — so say so.
        setTruncated((meta?.total_pages ?? 1) > 1);
      })
      .catch(() => addNotification({ type: 'error', message: 'Failed to load node instances' }))
      .finally(() => setLoadingInstances(false));
  }, [isOpen, addNotification]);

  const reset = () => {
    setNodeInstanceId('');
    setKind('');
    setSubmitting(false);
  };

  const handleClose = () => {
    if (submitting) return;
    reset();
    onClose();
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!nodeInstanceId) return;

    setSubmitting(true);
    try {
      const result = await sdwanApi.createHostBridge({
        node_instance_id: nodeInstanceId,
        kind: kind || undefined,
      });
      if (isPendingApproval(result)) {
        // Nothing was written — gate! never runs on_proceed on :pending. Close
        // the dialog, but do NOT report a creation the list would be refetched
        // for, which is the same rule the tab's activate and release handlers
        // keep.
        addNotification(pendingApprovalNotice('allocating the host bridge', result));
        reset();
        onClose();
        return;
      }
      addNotification({
        type: 'success',
        message:
          result.state === 'pending'
            ? `Bridge ${result.bridge_name} allocated (pending) — activate it to make it take effect.`
            : `Bridge ${result.bridge_name} is ${result.state} on this host.`,
      });
      reset();
      onCreated();
    } catch (err) {
      addNotification({
        type: 'error',
        message: apiErrorMessage(err, 'Failed to allocate bridge'),
      });
      setSubmitting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={handleClose}
      title="Allocate host bridge"
      icon={<NetworkIcon className="w-6 h-6" />}
    >
      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label
            className="block text-sm font-medium text-theme-primary mb-1"
            htmlFor="host-bridge-node-instance"
          >
            Host
          </label>
          <select
            id="host-bridge-node-instance"
            value={nodeInstanceId}
            onChange={(e) => setNodeInstanceId(e.target.value)}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
            disabled={submitting || loadingInstances}
          >
            <option value="">{loadingInstances ? 'Loading…' : 'Select a host'}</option>
            {instances.map((i) => (
              <option key={i.id} value={i.id}>
                {i.name} ({i.status})
              </option>
            ))}
          </select>
          {/* The host's network_profile decides the default kind, but
              SystemNodeInstance does not carry it (the field is on the bridge
              payload, not the instance one), so it is not shown here rather
              than guessed. */}
          {truncated && (
            <p className="text-xs text-theme-warning-fg mt-1">
              Showing hosts from the first {HOST_PAGE_SIZE} nodes only. A host on a later
              page is not listed here — allocate its bridge through the SDWAN agent.
            </p>
          )}
        </div>

        <div>
          <label
            className="block text-sm font-medium text-theme-primary mb-1"
            htmlFor="host-bridge-kind"
          >
            Kind <span className="text-xs text-theme-secondary">(optional)</span>
          </label>
          <select
            id="host-bridge-kind"
            value={kind}
            onChange={(e) => setKind(e.target.value as SdwanHostBridgeKind | '')}
            className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
            disabled={submitting}
          >
            <option value="">Let the allocator decide (from the host&apos;s profile)</option>
            <option value="linux">linux</option>
            <option value="ovs">ovs</option>
          </select>
          <p className="text-xs text-theme-secondary mt-1">
            Left alone, the allocator picks from the host&apos;s network profile: heavyweight
            gets OVS, lightweight gets a Linux bridge. Override only to disagree with it.
          </p>
        </div>

        <p className="text-xs text-theme-tertiary">
          A newly allocated bridge starts in <span className="font-mono">pending</span> and is
          invisible to the topology compiler until it is activated. Allocation is idempotent:
          if this host already has a bridge of the resolved kind you get that one back, and a
          previously released one is revived straight to <span className="font-mono">active</span>.
        </p>

        <div className="flex justify-end gap-2 pt-2">
          {/* Explicit type: the shared Button sets none, so inside a <form> it
              would default to submit and fire handleSubmit on the way out. */}
          <Button type="button" variant="secondary" onClick={handleClose} disabled={submitting}>
            Cancel
          </Button>
          <Button variant="primary" type="submit" disabled={submitting || !nodeInstanceId}>
            {submitting ? 'Allocating…' : 'Allocate'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
