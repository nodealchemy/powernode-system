import React, { useEffect, useState, useCallback, useMemo } from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { Plus } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import type { PageAction } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '@system/features/system/services/api/sdwanApi';
import type { SdwanRoutingOverview, SdwanRoutePolicy } from '@system/features/system/types/sdwan.types';
import { AsNumberSetupBanner } from '@system/features/system/components/sdwan/routing/AsNumberSetupBanner';
import { RoutingOverviewPanel } from '@system/features/system/components/sdwan/routing/RoutingOverviewPanel';
import { BgpSessionsTable } from '@system/features/system/components/sdwan/routing/BgpSessionsTable';
import { RoutePoliciesList } from '@system/features/system/components/sdwan/routing/RoutePoliciesList';
import { RoutePolicyEditModal } from '@system/features/system/components/sdwan/routing/RoutePolicyEditModal';

// Phase B.1 (also slice 9d2 follow-up) — path-based tabs match the
// canonical AdminSettingsPage pattern. Each tab is a child route under
// /app/system/sdwan/routing/<slug>.

type TabKey = 'overview' | 'sessions' | 'policies';

const TABS: { key: TabKey; label: string }[] = [
  { key: 'overview', label: 'Overview' },
  { key: 'sessions', label: 'BGP Sessions' },
  { key: 'policies', label: 'Route Policies' },
];

const BASE_PATH = '/app/system/sdwan/routing';

const SdwanRoutingPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const location = useLocation();
  const canManage = hasPermission('sdwan.routing.manage');
  const canRead = hasPermission('sdwan.routing.read');
  const canManagePolicies = hasPermission('sdwan.route_policies.manage');

  const [data, setData] = useState<SdwanRoutingOverview | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [policyToEdit, setPolicyToEdit] = useState<SdwanRoutePolicy | null | undefined>(undefined);
  const [policyToDelete, setPolicyToDelete] = useState<SdwanRoutePolicy | null>(null);

  const activeTab = useMemo<TabKey>(() => {
    const match = TABS.find((t) => location.pathname.endsWith(`/${t.key}`));
    return match?.key ?? 'overview';
  }, [location.pathname]);

  const load = useCallback(async () => {
    try {
      setLoading(true);
      setError(null);
      const result = await sdwanApi.getRoutingOverview();
      setData(result);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load routing overview');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (canRead) load();
  }, [load, canRead, refreshKey]);

  const handleDeletePolicy = async () => {
    if (!policyToDelete) return;
    try {
      await sdwanApi.deleteRoutePolicy(policyToDelete.id);
      addNotification?.({ type: 'success', message: `Policy '${policyToDelete.name}' deleted.` });
      setPolicyToDelete(null);
      setRefreshKey((k) => k + 1);
    } catch (err) {
      addNotification?.({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete policy',
      });
    }
  };

  const handleTogglePolicy = async (p: SdwanRoutePolicy) => {
    try {
      await sdwanApi.updateRoutePolicy(p.id, { enabled: !p.enabled });
      setRefreshKey((k) => k + 1);
    } catch (err) {
      addNotification?.({
        type: 'error',
        message: err instanceof Error ? err.message : 'Failed to toggle policy',
      });
    }
  };

  if (!canRead) {
    return (
      <PageContainer title="SDWAN Routing">
        <div className="p-4 bg-theme-danger text-theme-danger rounded text-sm">
          You don't have permission to view SDWAN routing.
        </div>
      </PageContainer>
    );
  }

  const pageActions: PageAction[] = [];
  if (activeTab === 'policies' && canManagePolicies) {
    pageActions.push({
      label: 'New policy',
      onClick: () => setPolicyToEdit(null),
      variant: 'primary',
      icon: Plus,
    });
  }

  return (
    <PageContainer
      title="SDWAN Routing"
      description="Account-level routing dashboard. AS allocation, BGP sessions, and learned routes across every iBGP-enabled SDWAN network in this account."
      actions={pageActions}
    >
      <div className="space-y-5">
        {loading && !data ? (
          <div className="p-4 text-theme-secondary">Loading routing overview…</div>
        ) : error ? (
          <div className="p-3 bg-theme-danger text-theme-danger rounded text-sm">{error}</div>
        ) : data ? (
          <>
            <AsNumberSetupBanner
              accountBgp={data.account_bgp}
              canManage={canManage}
              onAllocated={() => setRefreshKey((k) => k + 1)}
            />

            <div className="border-b border-theme flex gap-2">
              {TABS.map((t) => {
                const active = activeTab === t.key;
                return (
                  <Link
                    key={t.key}
                    to={`${BASE_PATH}/${t.key}`}
                    className={
                      'px-3 py-2 text-sm font-medium border-b-2 transition-colors ' +
                      (active
                        ? 'border-theme-focus text-theme-primary'
                        : 'border-transparent text-theme-secondary hover:text-theme-primary')
                    }
                  >
                    {t.label}
                  </Link>
                );
              })}
            </div>

            <Routes>
              <Route index element={<Navigate to="overview" replace />} />
              <Route path="overview" element={<RoutingOverviewPanel data={data} />} />
              <Route path="sessions" element={<BgpSessionsTable refreshKey={refreshKey} />} />
              <Route
                path="policies"
                element={
                  <RoutePoliciesList
                    refreshKey={refreshKey}
                    onEdit={canManagePolicies ? (p) => setPolicyToEdit(p) : undefined}
                    onDelete={canManagePolicies ? (p) => setPolicyToDelete(p) : undefined}
                    onToggle={canManagePolicies ? handleTogglePolicy : undefined}
                  />
                }
              />
              <Route path="*" element={<Navigate to="overview" replace />} />
            </Routes>

            {policyToEdit !== undefined && (
              <RoutePolicyEditModal
                policy={policyToEdit}
                onClose={() => setPolicyToEdit(undefined)}
                onSaved={() => {
                  setPolicyToEdit(undefined);
                  setRefreshKey((k) => k + 1);
                  addNotification?.({ type: 'success', message: 'Route policy saved.' });
                }}
              />
            )}

            {policyToDelete && (
              <Modal isOpen onClose={() => setPolicyToDelete(null)} title="Delete route policy" size="md">
                <div className="space-y-3">
                  <p className="text-sm text-theme-primary">
                    Delete policy <strong>{policyToDelete.name}</strong>? On the next agent reconcile, the
                    corresponding <code className="font-mono text-xs">route-map {policyToDelete.slug}-{policyToDelete.direction}</code>{' '}
                    will be removed from FRR config and any neighbor currently filtered by this policy will pass
                    routes unfiltered.
                  </p>
                  <div className="flex justify-end gap-2">
                    <Button variant="secondary" onClick={() => setPolicyToDelete(null)}>Cancel</Button>
                    <Button variant="danger" onClick={handleDeletePolicy}>Delete</Button>
                  </div>
                </div>
              </Modal>
            )}
          </>
        ) : null}
      </div>
    </PageContainer>
  );
};

export default SdwanRoutingPage;
