import { FC, useEffect, useState } from 'react';
import {
  marketplaceApi,
  type MarketplaceModuleDetail,
  type MarketplaceVersion,
  type MarketplaceDependency,
} from '../../services/api/marketplaceApi';
import { logger } from '@/shared/utils/logger';

interface Props {
  moduleId: string;
  onClose: () => void;
}

export const ModuleDetailModal: FC<Props> = ({ moduleId, onClose }) => {
  const [detail, setDetail] = useState<MarketplaceModuleDetail | null>(null);
  const [versions, setVersions] = useState<MarketplaceVersion[]>([]);
  const [dependencies, setDependencies] = useState<MarketplaceDependency[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    marketplaceApi
      .get(moduleId)
      .then((data) => {
        if (cancelled) return;
        setDetail(data.module);
        setVersions(data.recent_versions);
        setDependencies(data.dependencies);
        setError(null);
      })
      .catch((e) => {
        if (cancelled) return;
        logger.error('[ModuleDetailModal] fetch failed', e);
        setError(e instanceof Error ? e.message : 'Failed to load module');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [moduleId]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <div
        className="bg-theme-bg-card max-w-2xl w-full max-h-[80vh] overflow-auto rounded-lg p-6"
        onClick={(e) => e.stopPropagation()}
      >
        {loading && <div className="text-sm text-theme-text-muted">Loading...</div>}
        {error && <div className="text-sm text-theme-error">{error}</div>}

        {detail && (
          <div className="space-y-4">
            <div>
              <h2 className="text-xl font-semibold">{detail.name}</h2>
              {detail.description && (
                <p className="text-theme-text-secondary mt-1">{detail.description}</p>
              )}
            </div>

            <div className="grid grid-cols-2 gap-3 text-sm">
              <div>
                <div className="text-xs uppercase tracking-wider text-theme-text-muted">Trust Tier</div>
                <div>{detail.trust_tier}</div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wider text-theme-text-muted">Variety</div>
                <div>{detail.variety}</div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wider text-theme-text-muted">Category</div>
                <div>{detail.category || '—'}</div>
              </div>
              <div>
                <div className="text-xs uppercase tracking-wider text-theme-text-muted">Platform</div>
                <div>{detail.platform || '—'}</div>
              </div>
            </div>

            {versions.length > 0 && (
              <div>
                <div className="text-xs uppercase tracking-wider text-theme-text-muted mb-2">
                  Recent versions
                </div>
                <ul className="space-y-1 text-sm">
                  {versions.map((v) => (
                    <li key={v.id} className="flex justify-between">
                      <span>v{v.version_number}</span>
                      <span className="text-theme-text-muted text-xs">
                        {new Date(v.created_at).toLocaleDateString()}
                      </span>
                    </li>
                  ))}
                </ul>
              </div>
            )}

            {dependencies.length > 0 && (
              <div>
                <div className="text-xs uppercase tracking-wider text-theme-text-muted mb-2">
                  Dependencies
                </div>
                <ul className="space-y-1 text-sm">
                  {dependencies.map((d) => (
                    <li key={d.id}>
                      {d.required_module_name || d.required_module_id}
                      {d.required_version && (
                        <span className="text-theme-text-muted"> @ {d.required_version}</span>
                      )}
                    </li>
                  ))}
                </ul>
              </div>
            )}

            <div className="flex justify-end gap-2 pt-2 border-t border-theme-border-default">
              <button
                type="button"
                onClick={onClose}
                className="px-3 py-1.5 text-sm rounded border border-theme-border-default hover:bg-theme-bg-hover"
              >
                Close
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
};
