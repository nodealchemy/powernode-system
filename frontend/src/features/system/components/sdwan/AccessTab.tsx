import React, { useEffect, useState, useCallback } from 'react';
import { UserPlus, Plus, Smartphone, Trash2, Ban } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Modal } from '@/shared/components/ui/Modal';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanAccessGrant,
  SdwanUserDevice,
  SdwanIssueUserDeviceResponse,
} from '../../types/sdwan.types';
import { AccessGrantCreateModal } from './AccessGrantCreateModal';
import { UserDeviceIssueModal } from './UserDeviceIssueModal';
import { BootstrapUrlModal } from './BootstrapUrlModal';

interface AccessTabProps {
  networkId: string;
  refreshKey?: number;
}

/**
 * AccessTab — operator-side surface for the slice 4 user-VPN flow.
 * Renders one collapsible section per access grant; each section shows
 * the user's currently-issued devices with revoke/destroy actions.
 *
 * "Issue device" → calls UserDeviceIssueModal → calls
 * BootstrapUrlModal with the one-shot URL. Single-use semantics
 * are enforced server-side; the modal makes them visible to operators.
 */
export const AccessTab: React.FC<AccessTabProps> = ({ networkId, refreshKey }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canManage = hasPermission('sdwan.user_devices.manage');

  const [grants, setGrants] = useState<SdwanAccessGrant[]>([]);
  const [devicesByGrant, setDevicesByGrant] = useState<Record<string, SdwanUserDevice[]>>({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const [showGrantCreate, setShowGrantCreate] = useState(false);
  const [issueForGrantId, setIssueForGrantId] = useState<string | null>(null);
  const [bootstrapResult, setBootstrapResult] = useState<SdwanIssueUserDeviceResponse | null>(null);
  const [revokeGrantConfirm, setRevokeGrantConfirm] = useState<SdwanAccessGrant | null>(null);
  const [revokeDeviceConfirm, setRevokeDeviceConfirm] = useState<SdwanUserDevice | null>(null);

  const [localRefreshKey, setLocalRefreshKey] = useState(0);
  const triggerLocalRefresh = useCallback(() => setLocalRefreshKey((k) => k + 1), []);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const { grants: list } = await sdwanApi.getAccessGrants(networkId);
      setGrants(list);

      const deviceMap: Record<string, SdwanUserDevice[]> = {};
      await Promise.all(
        list.map(async (g) => {
          try {
            const r = await sdwanApi.getUserDevices(networkId, g.id);
            deviceMap[g.id] = r.devices;
          } catch {
            deviceMap[g.id] = [];
          }
        })
      );
      setDevicesByGrant(deviceMap);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load access state');
    } finally {
      setLoading(false);
    }
  }, [networkId]);

  useEffect(() => { load(); }, [load, refreshKey, localRefreshKey]);

  if (loading) return <div className="p-4 text-theme-secondary">Loading access state…</div>;
  if (error) return <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>;

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="text-sm text-theme-secondary">
          {grants.length} grant{grants.length === 1 ? '' : 's'} ·{' '}
          {Object.values(devicesByGrant).flat().length} device{Object.values(devicesByGrant).flat().length === 1 ? '' : 's'} total
        </div>
        {canManage && (
          <Button variant="primary" onClick={() => setShowGrantCreate(true)}>
            <UserPlus size={16} />
            <span className="ml-1">Grant access</span>
          </Button>
        )}
      </div>

      {grants.length === 0 ? (
        <div className="p-12 text-center text-theme-secondary">
          <UserPlus className="mx-auto mb-4" size={48} />
          <h3 className="text-lg font-medium text-theme-primary mb-1">No users have access yet</h3>
          <p className="text-sm">
            Grant a user access first, then issue them a WireGuard config.
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          {grants.map((g) => {
            const devices = devicesByGrant[g.id] ?? [];
            const isRevoked = g.status === 'revoked';
            return (
              <div key={g.id} className="border border-theme rounded">
                <div className="flex items-center justify-between p-3 bg-theme-background-secondary">
                  <div>
                    <div className="font-medium text-theme-primary">
                      {g.user_email ?? g.user_id}
                    </div>
                    <div className="text-xs text-theme-secondary">
                      {g.status} · {g.tags.length > 0 && `tags: ${g.tags.join(', ')} · `}
                      granted {g.granted_at ? new Date(g.granted_at).toLocaleDateString() : '—'}
                    </div>
                  </div>
                  <div className="flex gap-2">
                    {canManage && !isRevoked && (
                      <>
                        <Button variant="secondary" onClick={() => setIssueForGrantId(g.id)}>
                          <Plus size={14} />
                          <span className="ml-1">Issue device</span>
                        </Button>
                        <Button variant="danger" onClick={() => setRevokeGrantConfirm(g)}>
                          <Ban size={14} />
                          <span className="ml-1">Revoke</span>
                        </Button>
                      </>
                    )}
                  </div>
                </div>
                {devices.length > 0 ? (
                  <table className="w-full text-sm">
                    <thead className="bg-theme-surface text-theme-secondary text-xs">
                      <tr>
                        <th className="text-left p-2">Device</th>
                        <th className="text-left p-2">Address</th>
                        <th className="text-left p-2">Status</th>
                        <th className="text-left p-2">Downloaded</th>
                        <th className="text-right p-2">Actions</th>
                      </tr>
                    </thead>
                    <tbody>
                      {devices.map((d) => (
                        <tr key={d.id} className="border-t border-theme">
                          <td className="p-2 text-theme-primary">
                            <Smartphone size={14} className="inline mr-1" />
                            {d.label}
                          </td>
                          <td className="p-2 font-mono text-xs text-theme-secondary">{d.assigned_address}</td>
                          <td className="p-2">
                            {d.revoked_at ? (
                              <span className="text-theme-danger">revoked</span>
                            ) : d.last_downloaded_at ? (
                              <span className="text-theme-success">active</span>
                            ) : (
                              <span className="text-theme-info">pending download</span>
                            )}
                          </td>
                          <td className="p-2 text-xs text-theme-secondary">
                            {d.last_downloaded_at ? new Date(d.last_downloaded_at).toLocaleString() : '—'}
                          </td>
                          <td className="p-2 text-right">
                            {canManage && !d.revoked_at && (
                              <button
                                type="button" onClick={() => setRevokeDeviceConfirm(d)}
                                className="text-theme-danger hover:bg-theme-danger p-1 rounded"
                                aria-label={`Revoke ${d.label}`}
                              >
                                <Trash2 size={14} />
                              </button>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <div className="p-4 text-sm text-theme-secondary text-center">
                    No devices issued yet.
                  </div>
                )}
              </div>
            );
          })}
        </div>
      )}

      <AccessGrantCreateModal
        isOpen={showGrantCreate}
        networkId={networkId}
        onClose={() => setShowGrantCreate(false)}
        onCreated={triggerLocalRefresh}
      />

      <UserDeviceIssueModal
        isOpen={issueForGrantId !== null}
        networkId={networkId}
        grantId={issueForGrantId ?? ''}
        onClose={() => setIssueForGrantId(null)}
        onIssued={(result) => { setBootstrapResult(result); triggerLocalRefresh(); }}
      />

      <BootstrapUrlModal
        isOpen={bootstrapResult !== null}
        result={bootstrapResult}
        onClose={() => setBootstrapResult(null)}
      />

      <Modal
        isOpen={revokeGrantConfirm !== null}
        onClose={() => setRevokeGrantConfirm(null)}
        title="Revoke access grant"
      >
        {revokeGrantConfirm && (
          <div className="space-y-3">
            <p className="text-theme-primary">
              Revoke access for <strong>{revokeGrantConfirm.user_email ?? revokeGrantConfirm.user_id}</strong>?
            </p>
            <p className="text-sm text-theme-secondary">
              This cascades to revoke all of the user's devices on this network. Vault entries are
              kept for 90 days for audit, then reaped by the daily sweep.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setRevokeGrantConfirm(null)}>Cancel</Button>
              <Button variant="danger" onClick={async () => {
                try {
                  await sdwanApi.revokeAccessGrant(networkId, revokeGrantConfirm.id);
                  addNotification({ type: 'success', message: 'Grant revoked' });
                  setRevokeGrantConfirm(null);
                  triggerLocalRefresh();
                } catch (err) {
                  addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Failed' });
                }
              }}>Revoke</Button>
            </div>
          </div>
        )}
      </Modal>

      <Modal
        isOpen={revokeDeviceConfirm !== null}
        onClose={() => setRevokeDeviceConfirm(null)}
        title="Revoke device"
      >
        {revokeDeviceConfirm && (
          <div className="space-y-3">
            <p className="text-theme-primary">
              Revoke device <strong>{revokeDeviceConfirm.label}</strong>?
            </p>
            <p className="text-sm text-theme-secondary">
              The agent drops it from the hub view on next reconcile. The Vault entry is kept for
              90 days for audit, then reaped.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setRevokeDeviceConfirm(null)}>Cancel</Button>
              <Button variant="danger" onClick={async () => {
                try {
                  const grantId = revokeDeviceConfirm.access_grant_id;
                  await sdwanApi.revokeUserDevice(networkId, grantId, revokeDeviceConfirm.id);
                  addNotification({ type: 'success', message: 'Device revoked' });
                  setRevokeDeviceConfirm(null);
                  triggerLocalRefresh();
                } catch (err) {
                  addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Failed' });
                }
              }}>Revoke</Button>
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
};
