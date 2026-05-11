import { FC, useEffect, useState, useMemo } from 'react';
import { packagesApi, type ResolveDependenciesPreview, type SystemPackageRepository } from '@system/features/system/services/api/packageRepositoriesApi';
import { logger } from '@/shared/utils/logger';

interface Props {
  repository: SystemPackageRepository;
  packageName: string;
  architectures: string[];
  open: boolean;
  onClose: () => void;
  onCreated: (topLevelModuleId: string) => void;
}

// Two-pane materialize UI:
//   * Left: read-only list of required closure (N packages, total size).
//   * Right: checkbox list of opt-in recommends, each row showing
//            target package + summary + size + transitive cost line.
// Total recompute on toggle. Final commit creates the closure + dispatches CI build.
export const CreateModuleFromPackageModal: FC<Props> = ({
  repository,
  packageName,
  architectures,
  open,
  onClose,
  onCreated,
}) => {
  const [preview, setPreview] = useState<ResolveDependenciesPreview | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selectedRecommends, setSelectedRecommends] = useState<Set<string>>(new Set());
  const [submitting, setSubmitting] = useState(false);
  const [arch] = useState(architectures[0] ?? 'amd64');

  useEffect(() => {
    if (!open) return;
    setLoading(true);
    setError(null);
    setSelectedRecommends(new Set());
    packagesApi
      .resolveDependencies({ repository_id: repository.id, package_name: packageName, architecture: arch })
      .then((p) => setPreview(p))
      .catch((e) => {
        logger.error('[CreateModuleModal] resolve failed', e);
        setError(e instanceof Error ? e.message : 'Failed to resolve dependencies');
      })
      .finally(() => setLoading(false));
  }, [open, repository.id, packageName, arch]);

  const totalSize = useMemo(() => {
    if (!preview) return 0;
    const required = preview.required_packages.reduce((sum, p) => sum + (p.installed_size_bytes ?? 0), 0);
    const extras = preview.recommends_candidates
      .filter((c) => selectedRecommends.has(c.to))
      .reduce((sum, c) => sum + c.installed_size_bytes, 0);
    return required + extras;
  }, [preview, selectedRecommends]);

  const totalModuleCount = useMemo(() => {
    if (!preview) return 0;
    const transitiveExtra = preview.recommends_candidates
      .filter((c) => selectedRecommends.has(c.to))
      .reduce((sum, c) => sum + 1 + c.transitive_required_if_chosen.length, 0);
    return preview.required_packages.length + transitiveExtra;
  }, [preview, selectedRecommends]);

  if (!open) return null;

  const formatSize = (b: number): string => {
    if (b < 1024) return `${b} B`;
    if (b < 1024 * 1024) return `${(b / 1024).toFixed(0)} KB`;
    return `${(b / 1024 / 1024).toFixed(1)} MB`;
  };

  const toggle = (name: string) => {
    setSelectedRecommends((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  };

  const handleCreate = async () => {
    setSubmitting(true);
    setError(null);
    try {
      const result = await packagesApi.createModuleFromPackage({
        repository_id: repository.id,
        package_name: packageName,
        architectures,
        recommends_selected: Array.from(selectedRecommends),
      });
      onCreated(result.top_level_module.id);
      onClose();
    } catch (e) {
      logger.error('[CreateModuleModal] create failed', e);
      setError(e instanceof Error ? e.message : 'Materialization failed');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="w-full max-w-4xl bg-theme-surface rounded-lg shadow-xl p-6 max-h-[90vh] flex flex-col">
        <div className="flex items-center justify-between mb-4">
          <div>
            <h2 className="text-lg font-semibold text-theme-primary">Create Module from Package</h2>
            <p className="text-sm text-theme-secondary mt-0.5">
              {packageName} <span className="opacity-60">·</span> {repository.name} <span className="opacity-60">·</span> {architectures.join(', ')}
            </p>
          </div>
          <button onClick={onClose} className="text-theme-secondary hover:text-theme-primary">×</button>
        </div>

        {error && (
          <div className="mb-3 p-2 bg-theme-danger/10 text-theme-danger rounded text-sm">{error}</div>
        )}

        {loading && <div className="p-6 text-center text-theme-secondary">Resolving dependency closure…</div>}

        {!loading && preview && (
          <div className="flex-1 grid grid-cols-2 gap-4 overflow-hidden">
            {/* LEFT — Required closure */}
            <section className="bg-theme-background-secondary rounded p-3 overflow-y-auto">
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-semibold text-theme-primary">Required dependencies</h3>
                <span className="text-xs text-theme-secondary">
                  {preview.required_packages.length} packages
                </span>
              </div>
              {preview.required_packages.length === 0 ? (
                <p className="text-sm text-theme-secondary italic">No transitive requires.</p>
              ) : (
                <ul className="space-y-1">
                  {preview.required_packages.map((p) => (
                    <li key={`${p.name}-${p.version}`} className="text-sm text-theme-primary">
                      <span className="font-mono">{p.name}</span>
                      <span className="text-xs text-theme-secondary ml-1">v{p.version}</span>
                      {p.installed_size_bytes !== undefined && (
                        <span className="text-xs text-theme-secondary ml-2">
                          {formatSize(p.installed_size_bytes)}
                        </span>
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </section>

            {/* RIGHT — Opt-in recommends */}
            <section className="bg-theme-background-secondary rounded p-3 overflow-y-auto">
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-semibold text-theme-primary">Optional recommends</h3>
                <span className="text-xs text-theme-secondary">
                  {selectedRecommends.size} / {preview.recommends_candidates.length} selected
                </span>
              </div>
              {preview.recommends_candidates.length === 0 ? (
                <p className="text-sm text-theme-secondary italic">No recommends offered.</p>
              ) : (
                <ul className="space-y-2">
                  {preview.recommends_candidates.map((c) => (
                    <li key={`${c.from}-${c.to}`} className="text-sm border border-theme rounded p-2">
                      <label className="flex items-start gap-2 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={selectedRecommends.has(c.to)}
                          onChange={() => toggle(c.to)}
                          className="mt-0.5"
                        />
                        <div className="flex-1">
                          <div className="font-mono text-theme-primary">{c.to}</div>
                          {c.summary && (
                            <div className="text-xs text-theme-secondary mt-0.5">{c.summary}</div>
                          )}
                          <div className="text-xs text-theme-secondary mt-1">
                            <span>recommended by {c.from}</span>
                            <span className="mx-1">·</span>
                            <span>{formatSize(c.installed_size_bytes)}</span>
                            {c.transitive_required_if_chosen.length > 0 && (
                              <>
                                <span className="mx-1">·</span>
                                <span>+{c.transitive_required_if_chosen.length} transitive deps</span>
                              </>
                            )}
                          </div>
                        </div>
                      </label>
                    </li>
                  ))}
                </ul>
              )}

              {preview.suggests_candidates.length > 0 && (
                <details className="mt-4 text-xs text-theme-secondary">
                  <summary className="cursor-pointer">Suggests ({preview.suggests_candidates.length}) — informational</summary>
                  <ul className="mt-2 space-y-1 pl-4">
                    {preview.suggests_candidates.map((c) => (
                      <li key={`${c.from}-${c.to}`}>{c.to} <span className="opacity-60">via {c.from}</span></li>
                    ))}
                  </ul>
                </details>
              )}
            </section>
          </div>
        )}

        {!loading && preview && (
          <div className="mt-4 pt-4 border-t border-theme flex items-center justify-between">
            <div className="text-sm text-theme-secondary">
              <span className="font-medium text-theme-primary">{totalModuleCount} NodeModules</span>
              <span className="mx-2">·</span>
              <span>~{formatSize(totalSize)} installed</span>
              <span className="mx-2">·</span>
              <span>{architectures.length} architecture{architectures.length === 1 ? '' : 's'}</span>
            </div>
            <div className="flex gap-2">
              <button
                onClick={onClose}
                className="px-3 py-2 text-sm rounded border border-theme text-theme-secondary hover:text-theme-primary"
              >
                Cancel
              </button>
              <button
                onClick={handleCreate}
                disabled={submitting || preview.errors.length > 0}
                className="px-4 py-2 text-sm rounded bg-theme-focus text-white hover:opacity-90 disabled:opacity-50"
              >
                {submitting ? 'Creating…' : `Create ${totalModuleCount} modules + dispatch build`}
              </button>
            </div>
          </div>
        )}

        {!loading && preview && preview.errors.length > 0 && (
          <div className="mt-2 text-xs text-theme-danger">
            Cannot proceed: {preview.errors.join('; ')}
          </div>
        )}
      </div>
    </div>
  );
};
