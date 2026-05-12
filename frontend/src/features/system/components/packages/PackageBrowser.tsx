import { FC, useCallback, useEffect, useMemo, useState } from 'react';
import { Package as PkgIcon, Sparkles } from 'lucide-react';
import {
  packagesApi,
  type PackageDiscoverResult,
  type SystemPackage,
  type SystemPackageRepository,
} from '@system/features/system/services/api/packageRepositoriesApi';
import { useInfiniteResourceList } from '@system/features/system/hooks/useResourceList';
import { logger } from '@/shared/utils/logger';
import { MultiSelectOption } from '@/shared/components/ui/MultiSelect';
import {
  PackageFilterBar,
  DEFAULT_SECTION_OPTIONS,
  type PackageBrowserMode,
} from './PackageFilterBar';

// Package list bound to a single PackageRepository. Two modes:
//
//   - browse:   useInfiniteResourceList over the search endpoint, with
//               structured filters (architectures, sections, license,
//               provides) + 300ms-debounced q. Infinite scroll via
//               sentinel-aware accumulator.
//
//   - discover: manual fetch against /system/packages/discover. Server
//               embeds the intent, returns top_k results ranked by
//               cosine similarity. Architecture/license/kind filters
//               apply; section/provides don't (handled by the
//               semantic ranking instead). Not paginated.
//
// Filter state (architectures, license) is preserved across mode
// switches; mode-specific inputs (q, provides, sections vs. intent)
// are not.

interface Props {
  repository: SystemPackageRepository;
  canCreateModule: boolean;
  onCreateModule: (packageName: string) => void;
  architectureOptions: MultiSelectOption[];
}

interface PackageFilters extends Record<string, unknown> {
  q: string;
  debouncedQ: string;
  architectures: string[];
  sections: string[];
  license: string;
  provides: string;
}

type DiscoverState =
  | { phase: 'idle' }
  | { phase: 'loading' }
  | { phase: 'done'; result: PackageDiscoverResult }
  | { phase: 'error'; message: string };

export const PackageBrowser: FC<Props> = ({
  repository,
  canCreateModule,
  onCreateModule,
  architectureOptions,
}) => {
  const [mode, setMode] = useState<PackageBrowserMode>('browse');
  const [intent, setIntent] = useState('');
  const [discover, setDiscover] = useState<DiscoverState>({ phase: 'idle' });

  const list = useInfiniteResourceList<SystemPackage, PackageFilters>({
    fetcher: async ({ page, per_page, filters }) => {
      const result = await packagesApi.search({
        repository_id: repository.id,
        q: filters.debouncedQ || undefined,
        architectures: filters.architectures.length ? filters.architectures : undefined,
        sections: filters.sections.length ? filters.sections : undefined,
        license: filters.license || undefined,
        provides: filters.provides || undefined,
        mode: filters.debouncedQ ? 'hybrid' : 'lexical',
        page,
        per_page,
      });
      const total = result.total ?? (result.packages.length === per_page ? page * per_page + 1 : page * per_page);
      const totalPages = Math.max(1, Math.ceil(total / per_page));
      return {
        items: result.packages,
        meta: {
          current_page: result.page,
          per_page: result.per_page,
          total_count: total,
          total_pages: totalPages,
          next_page: page < totalPages ? page + 1 : null,
          prev_page: page > 1 ? page - 1 : null,
        },
      };
    },
    initialFilters: {
      q: '',
      debouncedQ: '',
      architectures: [],
      sections: [],
      license: '',
      provides: '',
    },
    perPage: 30,
    errorMessage: 'Failed to search packages',
    serverFilterKey: (f) =>
      JSON.stringify({
        q: f.debouncedQ,
        archs: [...f.architectures].sort(),
        sects: [...f.sections].sort(),
        lic: f.license,
        prov: f.provides,
      }),
  });

  // 300ms debounce on q
  useEffect(() => {
    const t = setTimeout(() => {
      if (list.filters.q !== list.filters.debouncedQ) {
        list.setFilters({ ...list.filters, debouncedQ: list.filters.q });
      }
    }, 300);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [list.filters.q]);

  const sectionOptions = useMemo<MultiSelectOption[]>(() => {
    const dynamic = Array.from(
      new Set(list.items.map((p) => p.section).filter((s): s is string => Boolean(s)))
    );
    const seen = new Set(DEFAULT_SECTION_OPTIONS.map((o) => o.value));
    const extras: MultiSelectOption[] = dynamic
      .filter((s) => !seen.has(s))
      .map((s) => ({ value: s, label: s }));
    return [...DEFAULT_SECTION_OPTIONS, ...extras];
  }, [list.items]);

  const submitIntent = useCallback(async () => {
    if (!intent.trim()) return;
    setDiscover({ phase: 'loading' });
    try {
      const result = await packagesApi.discoverByIntent({
        intent,
        repository_ids: [repository.id],
        architectures: list.filters.architectures.length ? list.filters.architectures : undefined,
        license: list.filters.license || undefined,
        top_k: 50,
      });
      setDiscover({ phase: 'done', result });
    } catch (e) {
      logger.error('[PackageBrowser] discover failed', e);
      const message = e instanceof Error ? e.message : 'Discovery failed';
      setDiscover({ phase: 'error', message });
    }
  }, [intent, repository.id, list.filters.architectures, list.filters.license]);

  const renderRow = (p: SystemPackage, opts?: { similarity?: number; reason?: string }) => {
    const similarity = opts?.similarity ?? p.similarity;
    return (
      <li
        key={p.id}
        className="flex items-center justify-between px-2 py-1.5 rounded hover:bg-theme-background-secondary"
        data-testid={`package-row-${p.id}`}
      >
        <div className="min-w-0 flex-1">
          <div className="flex items-baseline gap-2 flex-wrap">
            <span className="font-mono text-sm text-theme-primary">{p.name}</span>
            <span className="text-xs text-theme-secondary">v{p.version}</span>
            <span className="text-xs text-theme-secondary">({p.architecture})</span>
            {p.license && (
              <span className="px-1.5 py-0.5 text-[10px] rounded bg-theme-background-secondary text-theme-secondary">
                {p.license}
              </span>
            )}
            {typeof similarity === 'number' && (
              <span className="px-1.5 py-0.5 text-[10px] rounded bg-theme-info/20 text-theme-info">
                {Math.round(similarity * 100)}% match
              </span>
            )}
          </div>
          {p.summary && (
            <div className="text-xs text-theme-secondary truncate max-w-2xl">{p.summary}</div>
          )}
          {opts?.reason && (
            <div className="text-[10px] text-theme-tertiary mt-0.5 truncate max-w-2xl italic">
              {opts.reason}
            </div>
          )}
          {p.provides_names && p.provides_names.length > 0 && !opts?.reason && (
            <div className="text-[10px] text-theme-tertiary mt-0.5 truncate max-w-2xl">
              provides: {p.provides_names.slice(0, 3).join(', ')}
              {p.provides_names.length > 3 && ` +${p.provides_names.length - 3} more`}
            </div>
          )}
        </div>
        {canCreateModule && (
          <button
            onClick={() => onCreateModule(p.name)}
            className="ml-3 px-2 py-1 text-xs rounded bg-theme-focus text-white hover:opacity-90 flex items-center gap-1 flex-shrink-0"
            data-testid={`package-create-module-${p.id}`}
          >
            <PkgIcon size={12} />
            Create module
          </button>
        )}
      </li>
    );
  };

  return (
    <section className="border-t border-theme pt-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-semibold text-theme-primary">
          Packages in {repository.name}
        </h3>
        {mode === 'browse' && (
          <div className="text-xs text-theme-secondary" data-testid="package-browser-count">
            {list.loading ? 'Loading…' : `${list.items.length} loaded`}
          </div>
        )}
        {mode === 'discover' && discover.phase === 'done' && (
          <div className="text-xs text-theme-secondary" data-testid="package-discover-confidence">
            confidence: <span className="font-medium">{discover.result.confidence}</span> ·{' '}
            {discover.result.results.length} results
          </div>
        )}
      </div>

      <div className="mb-3">
        <PackageFilterBar
          mode={mode}
          onModeChange={setMode}
          q={list.filters.q}
          onQChange={(q) => list.setFilters({ ...list.filters, q })}
          intent={intent}
          onIntentChange={setIntent}
          onSubmitIntent={submitIntent}
          discovering={discover.phase === 'loading'}
          architectures={list.filters.architectures}
          onArchitecturesChange={(architectures) =>
            list.setFilters({ ...list.filters, architectures })
          }
          architectureOptions={architectureOptions}
          sections={list.filters.sections}
          onSectionsChange={(sections) => list.setFilters({ ...list.filters, sections })}
          sectionOptions={sectionOptions}
          license={list.filters.license}
          onLicenseChange={(license) => list.setFilters({ ...list.filters, license })}
          provides={list.filters.provides}
          onProvidesChange={(provides) => list.setFilters({ ...list.filters, provides })}
        />
      </div>

      {/* === Browse mode body === */}
      {mode === 'browse' && (
        <>
          {list.loading ? (
            <div className="p-4 text-sm text-theme-secondary">Searching…</div>
          ) : list.items.length === 0 ? (
            <div className="p-6 text-center text-theme-secondary border border-dashed border-theme rounded text-sm">
              {repository.package_count === 0
                ? 'No packages synced yet — click the sync button on the repository row above.'
                : 'No packages match the current filters.'}
            </div>
          ) : (
            <>
              <ul
                className="space-y-1 max-h-[28rem] overflow-y-auto"
                data-testid="package-browser-list"
              >
                {list.items.map((p) => renderRow(p))}
              </ul>
              {list.hasMore && (
                <div className="mt-2 flex justify-center">
                  <button
                    onClick={list.loadMore}
                    disabled={list.loadingMore}
                    className="px-3 py-1 text-xs rounded border border-theme text-theme-secondary hover:bg-theme-background-secondary disabled:opacity-50"
                    data-testid="package-browser-load-more"
                  >
                    {list.loadingMore ? 'Loading…' : 'Load more'}
                  </button>
                </div>
              )}
            </>
          )}
        </>
      )}

      {/* === Discover mode body === */}
      {mode === 'discover' && (
        <>
          {discover.phase === 'idle' && (
            <div className="p-6 text-center text-theme-secondary border border-dashed border-theme rounded text-sm">
              <Sparkles size={14} className="inline mr-1" />
              Describe a capability above to find matching packages.
            </div>
          )}
          {discover.phase === 'loading' && (
            <div className="p-4 text-sm text-theme-secondary">Embedding intent and searching…</div>
          )}
          {discover.phase === 'error' && (
            <div className="p-4 text-sm text-theme-danger" data-testid="package-discover-error">
              {discover.message}
            </div>
          )}
          {discover.phase === 'done' && discover.result.results.length === 0 && (
            <div className="p-6 text-center text-theme-secondary border border-dashed border-theme rounded text-sm">
              No semantic matches — try Browse mode for keyword search.
            </div>
          )}
          {discover.phase === 'done' && discover.result.results.length > 0 && (
            <ul
              className="space-y-1 max-h-[28rem] overflow-y-auto"
              data-testid="package-discover-list"
            >
              {discover.result.results.map((r) =>
                renderRow(
                  {
                    id: r.package_id,
                    name: r.name,
                    version: r.version,
                    architecture: r.architecture,
                    summary: r.summary,
                    similarity: r.similarity,
                    package_repository_id: r.repository_id,
                    license: r.license,
                    provides_names: r.provides_names,
                  } as SystemPackage,
                  { similarity: r.similarity, reason: r.reason }
                )
              )}
            </ul>
          )}
        </>
      )}
    </section>
  );
};

export { DEFAULT_SECTION_OPTIONS } from './PackageFilterBar';
