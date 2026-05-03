import { FC, useEffect, useState } from 'react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { marketplaceApi, type MarketplaceModuleCard } from '../../../features/system/services/api/marketplaceApi';
import { ModuleCard } from '../../../features/system/components/marketplace/ModuleCard';
import { ModuleDetailModal } from '../../../features/system/components/marketplace/ModuleDetailModal';
import { logger } from '@/shared/utils/logger';

const MarketplacePage: FC = () => {
  const [modules, setModules] = useState<MarketplaceModuleCard[]>([]);
  const [loading, setLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [trustFilter, setTrustFilter] = useState<string>('');
  const [search, setSearch] = useState<string>('');
  const [selectedId, setSelectedId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    marketplaceApi
      .list({ trust_tier: trustFilter || undefined, search: search || undefined })
      .then((paginated) => {
        if (!cancelled) {
          setModules(paginated.modules);
          setError(null);
        }
      })
      .catch((e) => {
        if (!cancelled) {
          logger.error('[MarketplacePage] list failed', e);
          setError(e instanceof Error ? e.message : 'Failed to load marketplace');
        }
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [trustFilter, search]);

  return (
    <PageContainer title="Module Marketplace">
      <div className="flex gap-3 mb-4">
        <input
          type="search"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search modules..."
          className="flex-1 px-3 py-2 rounded border border-theme-border-default bg-theme-bg-input"
        />
        <select
          value={trustFilter}
          onChange={(e) => setTrustFilter(e.target.value)}
          className="px-3 py-2 rounded border border-theme-border-default bg-theme-bg-input"
        >
          <option value="">All trust tiers</option>
          <option value="internal">Internal</option>
          <option value="verified-publisher">Verified Publisher</option>
          <option value="community">Community</option>
        </select>
      </div>

      {loading && <div className="text-sm text-theme-text-muted">Loading marketplace...</div>}
      {error && <div className="text-sm text-theme-error">{error}</div>}

      {!loading && !error && modules.length === 0 && (
        <div className="text-sm text-theme-text-muted">
          No modules match the current filters.
        </div>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        {modules.map((mod) => (
          <ModuleCard key={mod.id} module={mod} onClick={() => setSelectedId(mod.id)} />
        ))}
      </div>

      {selectedId && (
        <ModuleDetailModal moduleId={selectedId} onClose={() => setSelectedId(null)} />
      )}
    </PageContainer>
  );
};

export default MarketplacePage;
