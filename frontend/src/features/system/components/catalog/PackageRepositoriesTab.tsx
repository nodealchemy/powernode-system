import { FC, useCallback, useEffect, useMemo, useState } from 'react';
import { Database, RefreshCw, Trash2 } from 'lucide-react';
import {
  packageRepositoriesApi,
  type PackageRepositoryKind,
  type PackageRepositoryVisibility,
  type SystemPackageRepository,
} from '@system/features/system/services/api/packageRepositoriesApi';
import { architecturesApi } from '@system/features/system/services/api/architecturesApi';
import { PackageRepositoryFormModal } from '@system/features/system/components/packages/PackageRepositoryFormModal';
import { CreateModuleFromPackageModal } from '@system/features/system/components/packages/CreateModuleFromPackageModal';
import { PackageBrowser } from '@system/features/system/components/packages/PackageBrowser';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { logger } from '@/shared/utils/logger';
import { MultiSelect, type MultiSelectOption } from '@/shared/components/ui/MultiSelect';

type ActionsAPI = { openCreate: () => void };
interface Props {
  onActionsReady?: (actions: ActionsAPI | null) => void;
}

interface RepoFilters extends Record<string, unknown> {
  search: string;
  kinds: PackageRepositoryKind[];
  visibilities: PackageRepositoryVisibility[];
}

const KIND_OPTIONS: MultiSelectOption[] = [
  { value: 'apt', label: 'apt', secondaryLabel: 'Debian/Ubuntu' },
  { value: 'rpm', label: 'rpm', secondaryLabel: 'RHEL/CentOS' },
  { value: 'dnf', label: 'dnf', secondaryLabel: 'Fedora' },
];

const VISIBILITY_OPTIONS: MultiSelectOption[] = [
  { value: 'account', label: 'account', secondaryLabel: 'private to this account' },
  { value: 'shared', label: 'shared', secondaryLabel: 'system-wide' },
];

export const PackageRepositoriesTab: FC<Props> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.package_repositories.create');
  const canSync = hasPermission('system.package_repositories.sync');
  const canDelete = hasPermission('system.package_repositories.delete');
  const canCreateModule = hasPermission('system.package_modules.create');

  const [editingRepo, setEditingRepo] = useState<SystemPackageRepository | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null);
  const [packageToCreate, setPackageToCreate] = useState<{
    repository: SystemPackageRepository;
    packageName: string;
  } | null>(null);
  const [armedDelete, setArmedDelete] = useState<string | null>(null);
  const [architectureOptions, setArchitectureOptions] = useState<MultiSelectOption[]>([]);

  const list = useResourceList<SystemPackageRepository, RepoFilters>({
    fetcher: () => packageRepositoriesApi.list(),
    initialFilters: { search: '', kinds: [], visibilities: [] },
    filterFn: (repo, f) => {
      if (f.search) {
        const q = f.search.toLowerCase();
        const hit =
          repo.name.toLowerCase().includes(q) ||
          repo.base_url.toLowerCase().includes(q);
        if (!hit) return false;
      }
      if (f.kinds.length && !f.kinds.includes(repo.kind)) return false;
      if (f.visibilities.length) {
        const repoVisibility: PackageRepositoryVisibility = repo.shared ? 'shared' : 'account';
        if (!f.visibilities.includes(repoVisibility)) return false;
      }
      return true;
    },
    errorMessage: 'Failed to load package repositories',
  });

  useEffect(() => {
    if (canCreate) {
      onActionsReady?.({ openCreate: () => { setEditingRepo(null); setFormOpen(true); } });
    } else {
      onActionsReady?.(null);
    }
    return () => onActionsReady?.(null);
  }, [canCreate, onActionsReady]);

  useEffect(() => {
    let cancelled = false;
    architecturesApi
      .getArchitectures({ is_canonical: true, enabled: true })
      .then((archs) => {
        if (cancelled) return;
        const opts: MultiSelectOption[] = archs.map((a) => ({
          value: a.name,
          label: a.display_name || a.name,
          group: a.family,
          secondaryLabel: [a.apt_name, a.rpm_name].filter(Boolean).join(' / ') || undefined,
        }));
        setArchitectureOptions(opts);
      })
      .catch((e) => logger.error('[PackageRepositoriesTab] architectures load failed', e));
    return () => {
      cancelled = true;
    };
  }, []);

  const selectedRepo = useMemo(
    () => list.items.find((r) => r.id === selectedRepoId) ?? null,
    [list.items, selectedRepoId]
  );

  const handleSync = useCallback(
    async (repo: SystemPackageRepository) => {
      if (!canSync) return;
      const result = await packageRepositoriesApi.sync(repo.id);
      logger.info('[PackageRepositoriesTab] sync result', result);
      list.refresh();
    },
    [canSync, list]
  );

  const handleDelete = useCallback(
    async (repo: SystemPackageRepository) => {
      if (!canDelete) return;
      // Arm-and-confirm: first click arms, second commits within 5s
      if (armedDelete !== repo.id) {
        setArmedDelete(repo.id);
        setTimeout(() => setArmedDelete((cur) => (cur === repo.id ? null : cur)), 5000);
        return;
      }
      await packageRepositoriesApi.delete(repo.id);
      setArmedDelete(null);
      if (selectedRepoId === repo.id) setSelectedRepoId(null);
      list.refresh();
    },
    [armedDelete, canDelete, selectedRepoId, list]
  );

  const renderActions = (r: SystemPackageRepository) => (
    <div className="flex gap-2 justify-end">
      {canSync && (
        <button
          onClick={() => handleSync(r)}
          className="p-1 text-theme-secondary hover:text-theme-primary"
          title="Sync now"
          data-testid={`package-repo-sync-${r.id}`}
        >
          <RefreshCw size={14} />
        </button>
      )}
      <button
        onClick={() => { setEditingRepo(r); setFormOpen(true); }}
        className="p-1 text-theme-secondary hover:text-theme-primary"
        title="Edit"
        data-testid={`package-repo-edit-${r.id}`}
      >
        <Database size={14} />
      </button>
      {canDelete && (
        <button
          onClick={() => handleDelete(r)}
          className={
            'p-1 ' +
            (armedDelete === r.id
              ? 'text-theme-danger'
              : 'text-theme-secondary hover:text-theme-danger')
          }
          title={armedDelete === r.id ? 'Click again to confirm delete' : 'Delete'}
          data-testid={`package-repo-delete-${r.id}`}
        >
          <Trash2 size={14} />
        </button>
      )}
    </div>
  );

  const visibilityBadge = (r: SystemPackageRepository) =>
    r.shared ? (
      <span className="px-2 py-0.5 rounded text-xs bg-theme-info/20 text-theme-info">shared</span>
    ) : (
      <span className="px-2 py-0.5 rounded text-xs bg-theme-background-secondary text-theme-secondary">
        account
      </span>
    );

  const syncBadge = (r: SystemPackageRepository) => (
    <span
      className={
        'px-2 py-0.5 rounded text-xs ' +
        (r.sync_status === 'idle'
          ? 'bg-theme-success/20 text-theme-success'
          : r.sync_status === 'syncing'
            ? 'bg-theme-warning/20 text-theme-warning'
            : 'bg-theme-danger/20 text-theme-danger')
      }
    >
      {r.sync_status}
    </span>
  );

  return (
    <div className="space-y-6">
      <section>
        <h3 className="text-sm font-semibold text-theme-primary mb-2">Package Repositories</h3>
        <ResponsiveListContainer
          loading={list.loading}
          refreshing={list.refreshing}
          totalCount={list.items.length}
          filteredCount={list.filteredItems.length}
          onRefresh={() => list.refresh()}
          emptyState={{
            icon: Database,
            title: 'No package repositories',
            description:
              'Register an apt or rpm source — use the Create action above.',
          }}
        >
          <ResponsiveListContainer.Filters>
            <div className="flex flex-wrap items-center gap-2">
              <input
                type="search"
                value={list.filters.search}
                onChange={(e) => list.setFilters({ ...list.filters, search: e.target.value })}
                placeholder="Search by name or URL…"
                data-testid="package-repo-filter-search"
                className="flex-1 min-w-[12rem] px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
              />
              <div className="w-44" data-testid="package-repo-filter-kinds-wrap">
                <MultiSelect
                  ariaLabel="Kind filter"
                  options={KIND_OPTIONS}
                  value={list.filters.kinds}
                  onChange={(next) =>
                    list.setFilters({ ...list.filters, kinds: next as PackageRepositoryKind[] })
                  }
                  placeholder="Kind…"
                />
              </div>
              <div className="w-44" data-testid="package-repo-filter-visibilities-wrap">
                <MultiSelect
                  ariaLabel="Visibility filter"
                  options={VISIBILITY_OPTIONS}
                  value={list.filters.visibilities}
                  onChange={(next) =>
                    list.setFilters({
                      ...list.filters,
                      visibilities: next as PackageRepositoryVisibility[],
                    })
                  }
                  placeholder="Visibility…"
                />
              </div>
            </div>
          </ResponsiveListContainer.Filters>

          <ResponsiveListContainer.Desktop>
            <table className="w-full text-sm border-collapse">
              <thead>
                <tr className="border-b border-theme text-left text-xs text-theme-secondary uppercase tracking-wide">
                  <th className="p-2">Name</th>
                  <th className="p-2">Kind</th>
                  <th className="p-2">Visibility</th>
                  <th className="p-2">Status</th>
                  <th className="p-2 text-right">Packages</th>
                  <th className="p-2 text-right">Pending Embeddings</th>
                  <th className="p-2 text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {list.filteredItems.map((r) => (
                  <tr
                    key={r.id}
                    onClick={() => setSelectedRepoId(r.id)}
                    data-testid={`package-repo-row-${r.id}`}
                    className={
                      'border-b border-theme cursor-pointer hover:bg-theme-background-secondary ' +
                      (selectedRepoId === r.id ? 'bg-theme-background-secondary' : '')
                    }
                  >
                    <td className="p-2">
                      <div className="font-medium text-theme-primary">{r.name}</div>
                      <div className="text-xs text-theme-secondary truncate max-w-md">{r.base_url}</div>
                    </td>
                    <td className="p-2 text-theme-primary">{r.kind}</td>
                    <td className="p-2">{visibilityBadge(r)}</td>
                    <td className="p-2">
                      {syncBadge(r)}
                      {r.last_synced_at && (
                        <div className="text-xs text-theme-secondary mt-0.5">
                          {new Date(r.last_synced_at).toLocaleString()}
                        </div>
                      )}
                    </td>
                    <td className="p-2 text-right text-theme-primary">
                      {r.package_count.toLocaleString()}
                    </td>
                    <td className="p-2 text-right">
                      {typeof r.embedding_pending_count === 'number' ? (
                        r.embedding_pending_count === 0 ? (
                          <span className="text-xs text-theme-success">embedded</span>
                        ) : (
                          <span className="text-xs text-theme-warning">
                            {r.embedding_pending_count.toLocaleString()}
                          </span>
                        )
                      ) : (
                        <span className="text-xs text-theme-tertiary">—</span>
                      )}
                    </td>
                    <td className="p-2 text-right" onClick={(e) => e.stopPropagation()}>
                      {renderActions(r)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </ResponsiveListContainer.Desktop>

          <ResponsiveListContainer.Mobile>
            <ul className="space-y-2">
              {list.filteredItems.map((r) => (
                <li
                  key={r.id}
                  onClick={() => setSelectedRepoId(r.id)}
                  data-testid={`package-repo-card-${r.id}`}
                  className={
                    'p-3 rounded border border-theme cursor-pointer ' +
                    (selectedRepoId === r.id
                      ? 'bg-theme-background-secondary'
                      : 'bg-theme-surface hover:bg-theme-background-secondary')
                  }
                >
                  <div className="flex items-center justify-between gap-2 mb-1">
                    <div className="font-medium text-theme-primary truncate">{r.name}</div>
                    <div onClick={(e) => e.stopPropagation()}>{renderActions(r)}</div>
                  </div>
                  <div className="text-xs text-theme-secondary truncate mb-1">{r.base_url}</div>
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className="px-2 py-0.5 rounded text-xs bg-theme-background-secondary text-theme-secondary">
                      {r.kind}
                    </span>
                    {visibilityBadge(r)}
                    {syncBadge(r)}
                    <span className="text-xs text-theme-secondary">
                      {r.package_count.toLocaleString()} pkgs
                    </span>
                    {typeof r.embedding_pending_count === 'number' &&
                      r.embedding_pending_count > 0 && (
                        <span className="text-xs text-theme-warning">
                          {r.embedding_pending_count.toLocaleString()} pending
                        </span>
                      )}
                  </div>
                </li>
              ))}
            </ul>
          </ResponsiveListContainer.Mobile>
        </ResponsiveListContainer>
      </section>

      {selectedRepo && (
        <PackageBrowser
          repository={selectedRepo}
          canCreateModule={canCreateModule}
          architectureOptions={architectureOptions}
          onCreateModule={(packageName) =>
            setPackageToCreate({ repository: selectedRepo, packageName })
          }
        />
      )}

      <PackageRepositoryFormModal
        repository={editingRepo}
        open={formOpen}
        onClose={() => setFormOpen(false)}
        onSaved={() => list.refresh()}
      />

      {packageToCreate && (
        <CreateModuleFromPackageModal
          repository={packageToCreate.repository}
          packageName={packageToCreate.packageName}
          architectures={packageToCreate.repository.architectures}
          open={true}
          onClose={() => setPackageToCreate(null)}
          onCreated={() => {
            setPackageToCreate(null);
            list.refresh();
          }}
        />
      )}
    </div>
  );
};
