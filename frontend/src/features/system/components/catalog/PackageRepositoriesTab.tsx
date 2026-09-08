import { FC, useCallback, useEffect, useMemo, useState } from 'react';
import { Database, Link, Link2Off, RefreshCw, Trash2, Unlink } from 'lucide-react';
import {
  packageRepositoriesApi,
  type PackageRepositoryKind,
  type PackageRepositoryVisibility,
  type StaleLinksReport,
  type SystemPackageRepository,
} from '@system/features/system/services/api/packageRepositoriesApi';
import { architecturesApi } from '@system/features/system/services/api/architecturesApi';
import { platformsApi } from '@system/features/system/services/api/platformsApi';
import { PackageRepositoryFormModal } from '@system/features/system/components/packages/PackageRepositoryFormModal';
import { CreateModuleFromPackageModal } from '@system/features/system/components/packages/CreateModuleFromPackageModal';
import { PackageBrowser } from '@system/features/system/components/packages/PackageBrowser';
import { ResponsiveListContainer } from '@system/features/system/components/shared/ResponsiveListContainer';
import { StatusBadge } from '@system/features/system/components/shared/StatusBadge';
import { useResourceList } from '@system/features/system/hooks/useResourceList';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { MultiSelect, type MultiSelectOption } from '@/shared/components/ui/MultiSelect';
import type { SystemNodePlatform } from '@system/features/system/types/system.types';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';

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
  const { showNotification } = useNotifications();
  const canCreate = hasPermission('system.package_repositories.create');
  const canSync = hasPermission('system.package_repositories.sync');
  const canDelete = hasPermission('system.package_repositories.delete');
  const canCreateModule = hasPermission('system.package_modules.create');
  const canViewRepos = hasPermission('system.package_repositories.view');
  // clean_stale_links branches its gate on the repo's visibility exactly the
  // way destroy does: a shared repo is reachable from every account, so it
  // takes manage_shared rather than a plain delete.
  const canManageShared = hasPermission('system.package_repositories.manage_shared');
  // link_platform / unlink_platform run through authorize_repo_mutation!, which
  // branches on visibility exactly the way destroy does — a shared repo takes
  // manage_shared, an account repo takes update.
  const canUpdate = hasPermission('system.package_repositories.update');

  const [editingRepo, setEditingRepo] = useState<SystemPackageRepository | null>(null);
  const [formOpen, setFormOpen] = useState(false);
  const [selectedRepoId, setSelectedRepoId] = useState<string | null>(null);
  const [packageToCreate, setPackageToCreate] = useState<{
    repository: SystemPackageRepository;
    packageName: string;
  } | null>(null);
  const [armedDelete, setArmedDelete] = useState<string | null>(null);
  const [architectureOptions, setArchitectureOptions] = useState<MultiSelectOption[]>([]);
  const [staleLinks, setStaleLinks] = useState<StaleLinksReport | null>(null);
  const [staleLinksLoading, setStaleLinksLoading] = useState(false);
  const [platforms, setPlatforms] = useState<SystemNodePlatform[]>([]);
  const [platformLinkBusyId, setPlatformLinkBusyId] = useState<string | null>(null);
  const [platformsError, setPlatformsError] = useState(false);
  const { confirm, close: closeConfirmation, ConfirmationDialog } = useConfirmation();

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

  // Platform catalogue for the per-repository link/unlink controls
  // (IMP-d1900addb504). Names come from here; the repo row only carries ids.
  useEffect(() => {
    let cancelled = false;
    platformsApi
      .getPlatforms()
      .then((list) => {
        if (cancelled) return;
        setPlatforms(list);
      })
      .catch((e) => {
        // getPlatforms needs system.platforms.read, which this tab does not
        // otherwise require. Swallowing the failure would render "No platforms
        // defined" — a claim about the data, not about the request.
        if (cancelled) return;
        setPlatformsError(true);
        logger.error('[PackageRepositoriesTab] platforms load failed', e);
      });
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
      try {
        // Async: the request returns as soon as the sync is queued; the repo
        // flips to "syncing" and the poll below tracks it to idle/failed.
        const result = await packageRepositoriesApi.sync(repo.id);
        logger.info('[PackageRepositoriesTab] sync queued', result);
        showNotification(`Sync started for ${repo.name} — running in the background.`, 'success');
        list.refresh();
      } catch (e) {
        logger.error('[PackageRepositoriesTab] sync failed to start', e);
        showNotification(`Failed to start sync for ${repo.name}`, 'error');
      }
    },
    [canSync, list, showNotification]
  );

  // While any repository is mid-sync, poll the list so the badge flips from
  // "syncing" to idle/failed without a manual refresh (the work runs on the
  // worker, out of the request that started it).
  const anySyncing = useMemo(
    () => list.items.some((r) => r.sync_status === 'syncing'),
    [list.items]
  );
  useEffect(() => {
    if (!anySyncing) return;
    const id = setInterval(() => list.refresh(), 5000);
    return () => clearInterval(id);
  }, [anySyncing, list]);

  const handleDelete = useCallback(
    async (repo: SystemPackageRepository) => {
      if (!canDelete) return;
      // Arm-and-confirm: first click arms, second commits within 5s
      if (armedDelete !== repo.id) {
        setArmedDelete(repo.id);
        setTimeout(() => setArmedDelete((cur) => (cur === repo.id ? null : cur)), 5000);
        return;
      }
      try {
        await packageRepositoriesApi.delete(repo.id);
        showNotification(`Deleted repository ${repo.name}`, 'success');
        if (selectedRepoId === repo.id) setSelectedRepoId(null);
        list.refresh();
      } catch (e) {
        // 403 on a shared repo, 422 when modules still link to it — the row
        // stays put; tell the operator instead of failing silently.
        logger.error('[PackageRepositoriesTab] delete failed', e);
        showNotification(`Failed to delete repository ${repo.name}`, 'error');
      } finally {
        // Always disarm, or a failed delete leaves the button primed to fire
        // again on the operator's next click. Guarded on this repo's id so a
        // slow in-flight delete cannot disarm a row armed since.
        setArmedDelete((cur) => (cur === repo.id ? null : cur));
      }
    },
    [armedDelete, canDelete, selectedRepoId, list, showNotification]
  );

  // The preview and any confirmation raised from it are scoped to ONE
  // repository. Selecting another (or deselecting) must drop both, or the
  // panel shows the previous repo's stale links under the new repo's name and
  // the confirmation's onConfirm still points at the old id.
  useEffect(() => {
    setStaleLinks(null);
    setStaleLinksLoading(false);
    closeConfirmation();
  }, [selectedRepoId, closeConfirmation]);

  const handlePreviewStaleLinks = useCallback(async () => {
    if (!selectedRepo) return;
    setStaleLinksLoading(true);
    try {
      const report = await packageRepositoriesApi.staleLinks(selectedRepo.id);
      setStaleLinks(report);
    } catch (e) {
      logger.error('[PackageRepositoriesTab] stale link audit failed', e);
      showNotification(`Failed to audit stale links for ${selectedRepo.name}`, 'error');
    } finally {
      setStaleLinksLoading(false);
    }
  }, [selectedRepo, showNotification]);

  const handleCleanStaleLinks = useCallback(() => {
    if (!selectedRepo || !staleLinks || staleLinks.stale_count === 0) return;
    const repo = selectedRepo;
    const count = staleLinks.stale_count;
    confirm({
      title: 'Clean stale links',
      message: `This permanently destroys ${count} stale link${
        count === 1 ? '' : 's'
      } from "${repo.name}" and the auto-generated modules behind them, including their versions and artifacts. Links whose module is still referenced are kept.`,
      confirmLabel: `Clean ${count} stale link${count === 1 ? '' : 's'}`,
      variant: 'danger',
      // useConfirmation's handleConfirm awaits this and does not catch, so a
      // rejection escaping here would leave the dialog open on an unhandled
      // promise. Report inside instead.
      onConfirm: async () => {
        try {
          // force: true is REQUIRED. PackageRepositoryStaleLinkService.clean!
          // silently degrades to a dry run without it and still answers ok —
          // the operator would confirm a destructive action, be told it
          // succeeded, and nothing would be destroyed. The danger confirmation
          // above IS the deliberate act that guard asks for.
          const result = await packageRepositoriesApi.cleanStaleLinks(repo.id, {
            force: true,
          });
          if (result.dry_run) {
            // Belt and braces: if the server ever answers dry_run to a forced
            // clean, say so rather than reporting a destroy that never happened.
            showNotification(
              `No stale links were destroyed in ${repo.name} — the server treated the request as a dry run`,
              'warning',
            );
          } else {
            showNotification(
              `Cleaned ${result.destroyed} stale link${
                result.destroyed === 1 ? '' : 's'
              } from ${repo.name} (${result.kept} kept)`,
              'success',
            );
          }
          const refreshed = await packageRepositoriesApi.staleLinks(repo.id);
          setStaleLinks(refreshed);
        } catch (e) {
          logger.error('[PackageRepositoriesTab] stale link clean failed', e);
          showNotification(`Failed to clean stale links from ${repo.name}`, 'error');
        }
      },
    });
  }, [selectedRepo, staleLinks, confirm, showNotification]);

  // Incremental link/unlink. The form modal reconciles the WHOLE set on save;
  // these touch one link at a time so an operator adding a platform cannot
  // silently drop links added elsewhere since the form was opened.
  const handleTogglePlatformLink = useCallback(
    async (repo: SystemPackageRepository, platform: SystemNodePlatform, linked: boolean) => {
      if (!(repo.shared ? canManageShared : canUpdate)) return;
      setPlatformLinkBusyId(platform.id);
      try {
        if (linked) {
          await packageRepositoriesApi.unlinkPlatform(repo.id, platform.id);
          showNotification(`Unlinked ${platform.name} from ${repo.name}`, 'success');
        } else {
          await packageRepositoriesApi.linkPlatform(repo.id, platform.id);
          showNotification(`Linked ${platform.name} to ${repo.name}`, 'success');
        }
        list.refresh();
      } catch (e) {
        // 403 on a shared repo without manage_shared, 422 on a cross-account
        // platform — the link is unchanged either way, so say so.
        logger.error('[PackageRepositoriesTab] platform link toggle failed', e);
        showNotification(
          `Failed to ${linked ? 'unlink' : 'link'} ${platform.name} ${linked ? 'from' : 'to'} ${repo.name}`,
          'error',
        );
      } finally {
        setPlatformLinkBusyId((cur) => (cur === platform.id ? null : cur));
      }
    },
    [canManageShared, canUpdate, list, showNotification],
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
              ? 'text-theme-danger-fg'
              : 'text-theme-secondary hover:text-theme-danger-fg')
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
      <span className="px-2 py-0.5 rounded text-xs bg-theme-info-bg text-theme-info-fg">shared</span>
    ) : (
      <span className="px-2 py-0.5 rounded text-xs bg-theme-background-secondary text-theme-secondary">
        account
      </span>
    );

  const syncBadge = (r: SystemPackageRepository) => (
    <StatusBadge status={r.sync_status} size="xs" />
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
                          <span className="text-xs text-theme-success-fg">embedded</span>
                        ) : (
                          <span className="text-xs text-theme-warning-fg">
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
                        <span className="text-xs text-theme-warning-fg">
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

      {selectedRepo && canViewRepos && (
        <section className="rounded border border-theme bg-theme-surface p-4">
          <div className="mb-2">
            <h3 className="text-sm font-medium text-theme-primary flex items-center gap-2">
              <Link size={14} />
              Linked platforms
            </h3>
            <p className="text-xs text-theme-secondary mt-0.5">
              Platforms whose nodes resolve packages from{' '}
              <span className="text-theme-primary">{selectedRepo.name}</span>. A repository with no
              links is platform-agnostic and offered everywhere its account can see it.
            </p>
          </div>

          {platformsError ? (
            <p className="text-xs text-theme-warning-fg">
              Platform list unavailable — the platforms could not be loaded, so this
              repository&apos;s links cannot be shown or changed here.
            </p>
          ) : platforms.length === 0 ? (
            <p className="text-xs text-theme-tertiary">No platforms defined.</p>
          ) : (
            <ul className="flex flex-wrap gap-2">
              {platforms.map((p) => {
                const linked = selectedRepo.node_platform_ids.includes(p.id);
                const mayToggle = selectedRepo.shared ? canManageShared : canUpdate;
                return (
                  <li
                    key={p.id}
                    className={
                      'flex items-center gap-1.5 px-2 py-1 rounded border text-xs ' +
                      (linked
                        ? 'border-theme-info-fg/40 bg-theme-info-bg text-theme-info-fg'
                        : 'border-theme text-theme-secondary')
                    }
                    data-testid={`package-repo-platform-${p.id}`}
                  >
                    <span>{p.name}</span>
                    {mayToggle && (
                      <button
                        type="button"
                        onClick={() => handleTogglePlatformLink(selectedRepo, p, linked)}
                        disabled={platformLinkBusyId === p.id}
                        title={linked ? `Unlink ${p.name}` : `Link ${p.name}`}
                        aria-label={
                          linked
                            ? `Unlink ${p.name} from ${selectedRepo.name}`
                            : `Link ${p.name} to ${selectedRepo.name}`
                        }
                        data-testid={
                          linked
                            ? `package-repo-unlink-platform-${p.id}`
                            : `package-repo-link-platform-${p.id}`
                        }
                        className="p-0.5 rounded hover:bg-theme-background-secondary disabled:opacity-40"
                      >
                        {linked ? <Unlink size={12} /> : <Link size={12} />}
                      </button>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </section>
      )}

      {selectedRepo && canViewRepos && (
        <section className="rounded border border-theme bg-theme-surface p-4">
          <div className="flex flex-wrap items-center justify-between gap-2 mb-2">
            <div>
              <h3 className="text-sm font-medium text-theme-primary flex items-center gap-2">
                <Link2Off size={14} />
                Stale links
              </h3>
              <p className="text-xs text-theme-secondary mt-0.5">
                Auto-generated links whose module no longer belongs to any template
                or assignment. Cleaning them destroys those modules.
              </p>
            </div>
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={handlePreviewStaleLinks}
                disabled={staleLinksLoading}
                className="px-2 py-1 text-xs rounded border border-theme text-theme-secondary hover:text-theme-primary disabled:opacity-50"
                data-testid="package-repo-stale-links-preview"
              >
                {staleLinksLoading ? 'Checking…' : 'Check stale links'}
              </button>
              {/* Preview-gated on purpose: the count in the confirm has to come
                  from a real audit, never a guess. */}
              {staleLinks &&
                staleLinks.stale_count > 0 &&
                (selectedRepo.shared ? canManageShared : canDelete) && (
                  <button
                    type="button"
                    onClick={handleCleanStaleLinks}
                    className="px-2 py-1 text-xs rounded border border-theme text-theme-danger-fg hover:bg-theme-background-secondary"
                    data-testid="package-repo-stale-links-clean"
                  >
                    Clean {staleLinks.stale_count} stale link
                    {staleLinks.stale_count === 1 ? '' : 's'}
                  </button>
                )}
            </div>
          </div>

          {staleLinks && (
            <div className="text-xs text-theme-secondary">
              <p className="mb-2">
                <span
                  className="font-medium text-theme-primary"
                  data-testid="package-repo-stale-links-count"
                >
                  {staleLinks.stale_count}
                </span>{' '}
                stale link{staleLinks.stale_count === 1 ? '' : 's'}
              </p>
              {staleLinks.stale_links.length > 0 && (
                <ul className="space-y-1">
                  {staleLinks.stale_links.map((link) => (
                    <li
                      key={link.id}
                      className="flex flex-wrap items-center gap-2"
                      data-testid={`package-repo-stale-link-${link.id}`}
                    >
                      <span className="text-theme-primary">{link.package_name}</span>
                      {link.package_version && <span>{link.package_version}</span>}
                      {link.architecture && (
                        <span className="px-1.5 py-0.5 rounded bg-theme-background-secondary">
                          {link.architecture}
                        </span>
                      )}
                      {link.node_module_name && <span>→ {link.node_module_name}</span>}
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </section>
      )}

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

      {ConfirmationDialog}

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
