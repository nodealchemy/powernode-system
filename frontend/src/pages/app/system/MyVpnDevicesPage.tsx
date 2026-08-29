import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Download, RefreshCw, ShieldOff, Smartphone } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { myDevicesApi } from '@system/features/system/services/api/myDevicesApi';
import type { SdwanMyDevice } from '@system/features/system/types/sdwan.types';

// My VPN — the RECIPIENT's surface for the agent-issued-device design
// (increment 3 of 5). The operator-facing twin lives in the SDWAN hub's
// Access tab; this page shows one user their OWN devices and nothing else.
//
// WHY THIS PAGE IS LOAD-BEARING, NOT COSMETIC
// -------------------------------------------
// The SPA authenticates with a JWT, so a bare browser link to the config
// endpoint does not work — a top-level navigation carries no Authorization
// header. Increments 2 and 3a built the authenticated retrieval and discovery
// routes, but until something in the UI fetches them WITH the session token, a
// device issued without a bootstrap URL (increment 4's whole point) is a
// keypair its recipient cannot practically reach.
//
// NO PERMISSION GATE — DELIBERATE, AND DO NOT "HARDEN" IT
// ------------------------------------------------------
// Authorization is OWNERSHIP, enforced server-side by scoping the query to the
// caller's own Sdwan::AccessGrant rows; every authenticated user may see their
// own devices and nobody else's. There is no `system.sdwan.my_devices.*`
// permission on the backend, and on this platform a permission name that is not
// code-defined and granted degrades to ADMIN-ONLY — so adding a gate here would
// lock out precisely the ordinary users this page exists to serve, while giving
// admins nothing they don't already have. The route is registered ungated for
// the same reason. (Platform rule that does still apply: access control is by
// permissions, never roles — neither is needed here.)
const MyVpnDevicesPage: React.FC = () => {
  const { addNotification } = useNotifications();

  const [devices, setDevices] = useState<SdwanMyDevice[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [downloadingId, setDownloadingId] = useState<string | null>(null);

  // Monotonic request token. `load` is reachable from three places (mount,
  // the Retry/Refresh control, and after a download), so two reads can be in
  // flight at once and a slow first response could otherwise land AFTER a
  // fresh second one and reinstate rows the server has already superseded —
  // including a stale `retrievable: true`. Only the newest request writes.
  const loadSeq = useRef(0);

  const load = useCallback(async () => {
    const seq = ++loadSeq.current;
    try {
      setLoading(true);
      setError(null);
      const list = await myDevicesApi.listMyDevices();
      if (seq !== loadSeq.current) return;
      setDevices(list);
    } catch (err) {
      if (seq !== loadSeq.current) return;
      setError(err instanceof Error ? err.message : 'Failed to load your devices');
    } finally {
      if (seq === loadSeq.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
    // Bumping the token on unmount makes any in-flight response a no-op
    // rather than a write into a torn-down component.
    return () => {
      loadSeq.current += 1;
    };
  }, [load]);

  const handleDownload = useCallback(
    async (device: SdwanMyDevice) => {
      setDownloadingId(device.id);
      try {
        await myDevicesApi.downloadMyDeviceConfig(device.id, device.label);
        addNotification({ type: 'success', message: `Downloaded config for ${device.label}` });
      } catch (err) {
        addNotification({
          type: 'error',
          message: err instanceof Error ? err.message : 'Download failed',
        });
      } finally {
        setDownloadingId(null);
        // RE-READ ON BOTH ARMS, deliberately.
        //
        // Success: the fetch stamped `last_downloaded_at` server-side, so the
        // row's derived status and timestamp are stale. The server owns both;
        // don't patch local state.
        //
        // Failure: a 410 is the server saying THIS ROW'S `retrievable` is no
        // longer true (the grant was suspended or the device revoked between
        // the list read and the click). Leaving the cached boolean in place
        // would keep offering a button that can only ever 410 again. The list
        // read is cheap and ownership-scoped, so re-reading on a merely
        // transient failure costs one request and changes nothing on screen.
        await load();
      }
    },
    [addNotification, load]
  );

  // Available in EVERY non-loading state, including the error state — a
  // transient failure on mount is exactly when a user needs to retry, and
  // hiding the control there leaves a full page reload as the only recovery.
  const reloadButton = (label: string) => (
    <Button variant="ghost" size="sm" onClick={load} aria-label="Refresh device list">
      <RefreshCw size={14} />
      <span className="ml-1">{label}</span>
    </Button>
  );

  return (
    <PageContainer
      title="My VPN"
      description="WireGuard configs for the devices issued to you. Each config contains a private key — download it once, keep it on the device that uses it, and don't forward it."
      breadcrumbs={[{ label: 'System', href: '/app/system' }, { label: 'My VPN' }]}
    >
      {loading ? (
        <div className="p-4 text-theme-secondary">Loading your devices…</div>
      ) : error ? (
        <div className="space-y-3">
          <div className="p-3 bg-theme-danger-bg text-theme-danger-fg rounded text-sm" role="alert">
            {error}
          </div>
          {reloadButton('Try again')}
        </div>
      ) : devices.length === 0 ? (
        // An empty list is a NORMAL state (no device has been issued to this
        // user yet), not a failure — say so plainly instead of showing an error.
        <div className="p-12 text-center text-theme-secondary">
          <Smartphone className="mx-auto mb-4" size={48} />
          <h3 className="text-lg font-medium text-theme-primary mb-1">No VPN devices yet</h3>
          <p className="text-sm mb-4">
            When someone issues you a VPN device it will appear here with its config to download.
          </p>
          {reloadButton('Refresh')}
        </div>
      ) : (
        <div className="border border-theme rounded overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-theme-surface text-theme-secondary text-xs">
              <tr>
                <th className="text-left p-2">Device</th>
                <th className="text-left p-2">Status</th>
                <th className="text-left p-2">Issued</th>
                <th className="text-left p-2">Last downloaded</th>
                <th className="text-right p-2">Config</th>
              </tr>
            </thead>
            <tbody>
              {devices.map((d) => (
                <tr key={d.id} className="border-t border-theme">
                  <td className="p-2 text-theme-primary">
                    <Smartphone size={14} className="inline mr-1" />
                    {d.label}
                  </td>
                  <td className="p-2">
                    <StatusBadge status={d.status} />
                  </td>
                  <td className="p-2 text-xs text-theme-secondary">
                    {d.created_at ? new Date(d.created_at).toLocaleDateString() : '—'}
                  </td>
                  <td className="p-2 text-xs text-theme-secondary">
                    {d.last_downloaded_at ? new Date(d.last_downloaded_at).toLocaleString() : '—'}
                  </td>
                  <td className="p-2 text-right">
                    {/*
                      GATED ON `retrievable`, NEVER ON `status`.

                      `retrievable` is the server's own `owner_retrievable?`
                      (`!revoked? && access_grant.active?`), surfaced as a
                      boolean by increment 3a so this UI does not re-derive it.
                      The two fields DISAGREE on a real row: a device whose
                      grant has been suspended still reads
                      `status: "pending_download"` while `retrievable` is
                      false. Gating on the status string would render a
                      download button the server answers 410 to.
                    */}
                    {d.retrievable ? (
                      <Button
                        variant="secondary"
                        size="sm"
                        loading={downloadingId === d.id}
                        disabled={downloadingId !== null}
                        onClick={() => handleDownload(d)}
                        aria-label={`Download config for ${d.label}`}
                      >
                        <Download size={14} />
                        <span className="ml-1">
                          {d.status === 'downloaded' ? 'Download again' : 'Download'}
                        </span>
                      </Button>
                    ) : (
                      <span
                        className="inline-flex items-center gap-1 text-xs text-theme-secondary"
                        data-testid={`unavailable-${d.id}`}
                      >
                        <ShieldOff size={14} />
                        {d.status === 'revoked'
                          ? 'Revoked — ask for a new device'
                          : 'Unavailable — your access is not active'}
                      </span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {!loading && !error && devices.length > 0 && (
        <div className="mt-4 flex items-start justify-between gap-4">
          <p className="text-xs text-theme-secondary max-w-2xl">
            Downloading is not single-use — you can fetch a config again if you lose it. Only do so
            when you actually need it: each download is recorded, and it consumes any one-time setup
            link you were sent for the same device, which then stops working.
          </p>
          {reloadButton('Refresh')}
        </div>
      )}
    </PageContainer>
  );
};

// Derived server-side (UserDevice has no status column); rendered here as a
// label only. It never decides whether the download control appears — see the
// comment on the Config cell above.
const StatusBadge: React.FC<{ status: SdwanMyDevice['status'] }> = ({ status }) => {
  if (status === 'revoked') return <span className="text-theme-danger-fg">revoked</span>;
  if (status === 'downloaded') return <span className="text-theme-success-fg">downloaded</span>;
  return <span className="text-theme-info-fg">not downloaded yet</span>;
};

export default MyVpnDevicesPage;
