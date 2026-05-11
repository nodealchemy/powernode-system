import { FC, useCallback, useEffect, useState } from 'react';
import { Plus, RefreshCw, Database, Package as PkgIcon, Trash2 } from 'lucide-react';
import {
  packageRepositoriesApi,
  packagesApi,
  type SystemPackageRepository,
  type SystemPackage,
} from '@system/features/system/services/api/packageRepositoriesApi';
import { PackageRepositoryFormModal } from '@system/features/system/components/packages/PackageRepositoryFormModal';
import { CreateModuleFromPackageModal } from '@system/features/system/components/packages/CreateModuleFromPackageModal';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { logger } from '@/shared/utils/logger';

type ActionsAPI = { openCreate: () => void };
interface Props {
  onActionsReady?: (actions: ActionsAPI | null) => void;
}

// Combined view: top half lists repositories, bottom half shows the
// browse + materialize flow for a selected repo. Keeps everything in one
// page since the Catalog tab is already a deep nav level.
export const PackageRepositoriesTab: FC<Props> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.package_repositories.create');
  const canSync = hasPermission('system.package_repositories.sync');
  const canDelete = hasPermission('system.package_repositories.delete');
  const canCreateModule = hasPermission('system.package_modules.create');

  const [repos, setRepos] = useState<SystemPackageRepository[]>([]);
  const [loading, setLoading] = useState(true);
  const [editingRepo, setEditingRepo] = useState<SystemPackageRepository | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null);
  const [packages, setPackages] = useState<SystemPackage[]>([]);
  const [packagesLoading, setPackagesLoading] = useState(false);
  const [packageQuery, setPackageQuery] = useState('');
  const [packageToCreate, setPackageToCreate] = useState<{
    repository: SystemPackageRepository;
    packageName: string;
  } | null>(null);
  const [armedDelete, setArmedDelete] = useState<string | null>(null);

  const loadRepos = useCallback(async () => {
    setLoading(true);
    try {
      setRepos(await packageRepositoriesApi.list());
    } catch (e) {
      logger.error('[PackageRepositoriesTab] list failed', e);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadRepos();
  }, [loadRepos]);

  useEffect(() => {
    if (canCreate) {
      onActionsReady?.({ openCreate: () => { setEditingRepo(null); setFormOpen(true); } });
    } else {
      onActionsReady?.(null);
    }
    return () => onActionsReady?.(null);
  }, [canCreate, onActionsReady]);

  const selectedRepo = repos.find((r) => r.id === selectedRepoId) ?? null;

  // Browse packages within the selected repo
  useEffect(() => {
    if (!selectedRepoId) {
      setPackages([]);
      return;
    }
    setPackagesLoading(true);
    packagesApi
      .search({ repository_id: selectedRepoId, q: packageQuery || undefined, per_page: 50 })
      .then(({ packages: pkgs }) => setPackages(pkgs))
      .catch((e) => logger.error('[PackageRepositoriesTab] search failed', e))
      .finally(() => setPackagesLoading(false));
  }, [selectedRepoId, packageQuery]);

  const handleSync = async (repo: SystemPackageRepository) => {
    if (!canSync) return;
    const result = await packageRepositoriesApi.sync(repo.id);
    logger.info('[PackageRepositoriesTab] sync result', result);
    loadRepos();
  };

  const handleDelete = async (repo: SystemPackageRepository) => {
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
    loadRepos();
  };

  return (
    <div className="space-y-6">
      {/* === Repositories table === */}
      <section>
        <h3 className="text-sm font-semibold text-theme-primary mb-2">Package Repositories</h3>
        {loading ? (
          <div className="p-4 text-sm text-theme-secondary">Loading…</div>
        ) : repos.length === 0 ? (
          <div className="p-6 text-center text-theme-secondary border border-dashed border-theme rounded">
            No package repositories yet. Click <strong>Create</strong> to register an apt or rpm source.
          </div>
        ) : (
          <table className="w-full text-sm border-collapse">
            <thead>
              <tr className="border-b border-theme text-left text-xs text-theme-secondary uppercase tracking-wide">
                <th className="p-2">Name</th>
                <th className="p-2">Kind</th>
                <th className="p-2">Visibility</th>
                <th className="p-2">Status</th>
                <th className="p-2 text-right">Packages</th>
                <th className="p-2 text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              {repos.map((r) => (
                <tr
                  key={r.id}
                  onClick={() => setSelectedRepoId(r.id)}
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
                  <td className="p-2">
                    {r.shared ? (
                      <span className="px-2 py-0.5 rounded text-xs bg-theme-info/20 text-theme-info">shared</span>
                    ) : (
                      <span className="px-2 py-0.5 rounded text-xs bg-theme-background-secondary text-theme-secondary">account</span>
                    )}
                  </td>
                  <td className="p-2">
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
                    {r.last_synced_at && (
                      <div className="text-xs text-theme-secondary mt-0.5">
                        {new Date(r.last_synced_at).toLocaleString()}
                      </div>
                    )}
                  </td>
                  <td className="p-2 text-right text-theme-primary">{r.package_count.toLocaleString()}</td>
                  <td className="p-2 text-right" onClick={(e) => e.stopPropagation()}>
                    <div className="flex gap-2 justify-end">
                      {canSync && (
                        <button
                          onClick={() => handleSync(r)}
                          className="p-1 text-theme-secondary hover:text-theme-primary"
                          title="Sync now"
                        >
                          <RefreshCw size={14} />
                        </button>
                      )}
                      <button
                        onClick={() => { setEditingRepo(r); setFormOpen(true); }}
                        className="p-1 text-theme-secondary hover:text-theme-primary"
                        title="Edit"
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
                        >
                          <Trash2 size={14} />
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {/* === Selected repo browser === */}
      {selectedRepo && (
        <section className="border-t border-theme pt-4">
          <div className="flex items-center justify-between mb-2">
            <h3 className="text-sm font-semibold text-theme-primary">
              Packages in {selectedRepo.name}
            </h3>
            <input
              type="search"
              value={packageQuery}
              onChange={(e) => setPackageQuery(e.target.value)}
              placeholder="Search packages..."
              className="px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary w-72"
            />
          </div>

          {packagesLoading ? (
            <div className="p-4 text-sm text-theme-secondary">Searching…</div>
          ) : packages.length === 0 ? (
            <div className="p-6 text-center text-theme-secondary border border-dashed border-theme rounded text-sm">
              {selectedRepo.package_count === 0
                ? 'No packages synced yet — click the sync button on the repository row above.'
                : 'No packages match the current filter.'}
            </div>
          ) : (
            <ul className="space-y-1 max-h-96 overflow-y-auto">
              {packages.map((p) => (
                <li
                  key={p.id}
                  className="flex items-center justify-between px-2 py-1.5 rounded hover:bg-theme-background-secondary"
                >
                  <div>
                    <span className="font-mono text-sm text-theme-primary">{p.name}</span>
                    <span className="text-xs text-theme-secondary ml-2">v{p.version}</span>
                    <span className="text-xs text-theme-secondary ml-1">({p.architecture})</span>
                    {p.summary && (
                      <div className="text-xs text-theme-secondary truncate max-w-2xl">{p.summary}</div>
                    )}
                  </div>
                  {canCreateModule && (
                    <button
                      onClick={() => setPackageToCreate({ repository: selectedRepo, packageName: p.name })}
                      className="px-2 py-1 text-xs rounded bg-theme-focus text-white hover:opacity-90 flex items-center gap-1"
                    >
                      <PkgIcon size={12} />
                      Create module
                    </button>
                  )}
                </li>
              ))}
            </ul>
          )}
        </section>
      )}

      <PackageRepositoryFormModal
        repository={editingRepo}
        open={formOpen}
        onClose={() => setFormOpen(false)}
        onSaved={() => loadRepos()}
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
            // After materialization, refresh the repo list so package_count updates
            loadRepos();
          }}
        />
      )}
    </div>
  );
};
