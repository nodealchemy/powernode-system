import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Hash, Trash2, Cpu, RefreshCw, CheckCircle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { wsManager } from '@/shared/services/WebSocketManager';
import { useAuth } from '@/shared/hooks/useAuth';
import { unclaimedDevicesApi } from '@system/features/system/services/api/unclaimedDevicesApi';
import { systemApi } from '@system/features/system/services/systemApi';
import type {
  SystemUnclaimedDevice,
  SystemNodeInstance,
  SystemNode,
} from '@system/features/system/types/system.types';

interface UnclaimedDevicesPanelProps {
  /** When set, pre-filters the claim modal's NodeInstance picker to instances
   *  belonging to this node. Otherwise the picker shows all of the operator's
   *  variety=physical pending instances. */
  scopedToNode?: SystemNode;
  /** Called after a successful claim — parent can refresh its instance list. */
  onClaimed?: (deviceId: string, nodeInstanceId: string) => void;
}

// Live operator-facing surface for the claim flow.
// Plan: docs/plans/wondrous-yawning-anchor.md §7.
//
// Lists devices polling /node_api/claim that haven't been bound yet.
// Live updates arrive via SystemFleetChannel — the
// system.physical_device_discovered FleetEvent emitted by
// PhysicalEnrollmentService.record_discovery! triggers a refresh.
export const UnclaimedDevicesPanel: React.FC<UnclaimedDevicesPanelProps> = ({
  scopedToNode,
  onClaimed,
}) => {
  const { addNotification } = useNotifications();
  const { currentUser } = useAuth();
  const accountId = (currentUser as { account?: { id?: string } } | null)?.account?.id;

  const [devices, setDevices] = useState<SystemUnclaimedDevice[]>([]);
  const [loading, setLoading] = useState(false);
  const [claimingId, setClaimingId] = useState<string | null>(null);
  const [discardingId, setDiscardingId] = useState<string | null>(null);

  // Modal state for confirm-and-claim
  const [pickerOpenFor, setPickerOpenFor] = useState<SystemUnclaimedDevice | null>(null);
  const [pickerInstances, setPickerInstances] = useState<SystemNodeInstance[]>([]);
  const [pickerSelected, setPickerSelected] = useState<string>('');

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await unclaimedDevicesApi.list();
      setDevices(result.devices);
    } catch {
      addNotification({ type: 'error', message: 'Failed to load unclaimed devices' });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Live updates via SystemFleetChannel — when the agent calls /node_api/claim
  // and PhysicalEnrollmentService emits system.physical_device_discovered, we
  // refresh so the operator sees new devices in real time.
  useEffect(() => {
    if (!accountId) return;
    const unsubscribe = wsManager.subscribe({
      channel: 'SystemFleetChannel',
      params: { account_id: accountId },
      onMessage: (data: unknown) => {
        const msg = data as { kind?: string };
        if (msg?.kind === 'system.physical_device_discovered' || msg?.kind === 'system.physical_device_claimed') {
          void refresh();
        }
      },
      onError: () => {},
    });
    return () => unsubscribe();
  }, [accountId, refresh]);

  const visibleDevices = useMemo(() => {
    return devices.filter((d) => !d.claimed_at);
  }, [devices]);

  const openPickerFor = useCallback(async (device: SystemUnclaimedDevice) => {
    setPickerOpenFor(device);
    setPickerSelected('');
    try {
      // Load NodeInstances for the operator's account (filtered to
      // physical+pending — those are the only valid claim targets).
      // We pull via the existing nodes API and flatten.
      const nodes = scopedToNode ? [scopedToNode] : await systemApi.getNodes().then((r) => r.nodes);
      const instances: SystemNodeInstance[] = [];
      for (const n of nodes) {
        const result = await systemApi.getNodeInstances(n.id);
        const list = result.node_instances ?? [];
        instances.push(
          ...list.filter((i) => i.variety === 'physical' && (i.status === 'pending' || !i.claimed_at)),
        );
      }
      setPickerInstances(instances);
    } catch {
      setPickerInstances([]);
      addNotification({ type: 'error', message: 'Failed to load claimable instances' });
    }
  }, [addNotification, scopedToNode]);

  const handleClaim = useCallback(async () => {
    if (!pickerOpenFor || !pickerSelected) return;
    const deviceId = pickerOpenFor.id;
    setClaimingId(deviceId);
    try {
      const res = await unclaimedDevicesApi.claim(deviceId, pickerSelected);
      addNotification({
        type: 'success',
        message: `Claimed device for ${res.node_instance_name}. Device will enroll on next poll.`,
      });
      onClaimed?.(deviceId, res.node_instance_id);
      setPickerOpenFor(null);
      setPickerSelected('');
      void refresh();
    } catch (e) {
      addNotification({
        type: 'error',
        message: e instanceof Error ? e.message : 'Claim failed',
      });
    } finally {
      setClaimingId(null);
    }
  }, [pickerOpenFor, pickerSelected, addNotification, onClaimed, refresh]);

  const handleDiscard = useCallback(async (device: SystemUnclaimedDevice) => {
    setDiscardingId(device.id);
    try {
      await unclaimedDevicesApi.discard(device.id);
      void refresh();
    } catch (e) {
      addNotification({
        type: 'error',
        message: e instanceof Error ? e.message : 'Discard failed',
      });
    } finally {
      setDiscardingId(null);
    }
  }, [addNotification, refresh]);

  return (
    <section className="bg-theme-surface rounded-lg border border-theme">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Cpu size={16} className="text-theme-info" />
          <h2 className="font-medium text-theme-primary">Unclaimed Devices</h2>
          {visibleDevices.length > 0 && (
            <Badge variant="info" size="xs">{visibleDevices.length}</Badge>
          )}
        </div>
        <Button size="xs" variant="ghost" onClick={refresh} disabled={loading} title="Refresh">
          <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
        </Button>
      </header>

      <div className="p-2">
        {visibleDevices.length === 0 ? (
          <p className="text-sm text-theme-secondary p-3">
            No devices waiting to be claimed.{' '}
            Flash a Powernode disk image onto an SD card and plug a device in to start the claim flow.
          </p>
        ) : (
          <ul className="divide-y divide-theme-border">
            {visibleDevices.map((d) => (
              <li key={d.id} className="px-3 py-2.5">
                <div className="flex items-center justify-between gap-3">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 text-sm">
                      <code className="text-theme-primary font-mono">{d.discovered_mac}</code>
                      {d.discovered_hostname && (
                        <span className="text-theme-secondary">({d.discovered_hostname})</span>
                      )}
                      {d.architecture && (
                        <Badge variant="default" size="xs">{d.architecture}</Badge>
                      )}
                      {d.platform_hint && (
                        <Badge variant="info" size="xs">{d.platform_hint}</Badge>
                      )}
                    </div>
                    <div className="flex items-center gap-2 mt-1 text-xs text-theme-tertiary">
                      <Hash size={12} />
                      <code className="text-theme-primary font-mono">{d.claim_code}</code>
                      <span className="text-theme-tertiary">
                        · last seen {new Date(d.last_seen_at).toLocaleTimeString()}
                      </span>
                    </div>
                  </div>
                  <div className="flex items-center gap-1">
                    <Button
                      size="sm"
                      variant="primary"
                      onClick={() => openPickerFor(d)}
                      disabled={claimingId === d.id}
                    >
                      <CheckCircle size={14} />
                      Claim
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => handleDiscard(d)}
                      disabled={discardingId === d.id}
                      title="Discard this device"
                    >
                      <Trash2 size={14} className="text-theme-error" />
                    </Button>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Claim picker modal */}
      {pickerOpenFor && (
        <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
          <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-lg p-6">
            <h3 className="text-lg font-semibold mb-2">Claim device</h3>
            <p className="text-sm text-theme-secondary mb-4">
              Bind device <code className="font-mono">{pickerOpenFor.discovered_mac}</code>
              {pickerOpenFor.discovered_hostname ? <> ({pickerOpenFor.discovered_hostname})</> : null}
              {' '}to which NodeInstance? The device&apos;s next claim poll will receive a
              single-use bootstrap token and proceed to enrollment automatically.
            </p>
            <select
              value={pickerSelected}
              onChange={(e) => setPickerSelected(e.target.value)}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary mb-4"
            >
              <option value="">Select a NodeInstance...</option>
              {pickerInstances.map((i) => (
                <option key={i.id} value={i.id}>
                  {i.name} ({i.node_name ?? i.node_id})
                </option>
              ))}
            </select>
            {pickerInstances.length === 0 && (
              <p className="text-xs text-theme-warning mb-3">
                No claimable instances. Create a variety=physical NodeInstance first.
              </p>
            )}
            <div className="flex justify-end gap-2">
              <Button variant="outline" onClick={() => { setPickerOpenFor(null); setPickerSelected(''); }}>
                Cancel
              </Button>
              <Button
                variant="primary"
                onClick={handleClaim}
                disabled={!pickerSelected || claimingId === pickerOpenFor.id}
              >
                Confirm claim
              </Button>
            </div>
          </div>
        </div>
      )}
    </section>
  );
};

export default UnclaimedDevicesPanel;
