import { FC, useEffect, useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
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
    <Modal
      isOpen
      onClose={onClose}
      variant="centered"
      size="2xl"
      title={detail?.name || 'Module'}
      subtitle={detail?.description}
      footer={
        <div className="flex justify-end">
          <Button variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      }
    >
      {loading && <div className="text-sm text-theme-tertiary">Loading...</div>}
      {error && <div className="text-sm text-theme-danger">{error}</div>}

      {detail && (
        <div className="space-y-4">
          <div className="grid grid-cols-2 gap-3 text-sm">
            <div>
              <div className="text-xs uppercase tracking-wider text-theme-tertiary">Trust Tier</div>
              <div className="text-theme-primary">{detail.trust_tier}</div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wider text-theme-tertiary">Variety</div>
              <div className="text-theme-primary">{detail.variety}</div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wider text-theme-tertiary">Category</div>
              <div className="text-theme-primary">{detail.category || '—'}</div>
            </div>
            <div>
              <div className="text-xs uppercase tracking-wider text-theme-tertiary">Platform</div>
              <div className="text-theme-primary">{detail.platform || '—'}</div>
            </div>
          </div>

          {versions.length > 0 && (
            <div>
              <div className="text-xs uppercase tracking-wider text-theme-tertiary mb-2">
                Recent versions
              </div>
              <ul className="space-y-1 text-sm">
                {versions.map((v) => (
                  <li key={v.id} className="flex justify-between text-theme-primary">
                    <span>v{v.version_number}</span>
                    <span className="text-theme-tertiary text-xs">
                      {new Date(v.created_at).toLocaleDateString()}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {dependencies.length > 0 && (
            <div>
              <div className="text-xs uppercase tracking-wider text-theme-tertiary mb-2">
                Dependencies
              </div>
              <ul className="space-y-1 text-sm">
                {dependencies.map((d) => (
                  <li key={d.id} className="text-theme-primary">
                    {d.required_module_name || d.required_module_id}
                    {d.required_version && (
                      <span className="text-theme-tertiary"> @ {d.required_version}</span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      )}
    </Modal>
  );
};
