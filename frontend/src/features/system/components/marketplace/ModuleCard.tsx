import { FC } from 'react';
import type { MarketplaceModuleCard } from '../../services/api/marketplaceApi';

interface Props {
  module: MarketplaceModuleCard;
  onClick: () => void;
}

const TRUST_TIER_STYLES: Record<string, string> = {
  internal: 'bg-theme-success-bg text-theme-success border-theme-success',
  'verified-publisher': 'bg-theme-info-bg text-theme-info border-theme-info',
  community: 'bg-theme-warning-bg text-theme-warning border-theme-warning',
};

export const ModuleCard: FC<Props> = ({ module, onClick }) => {
  const tierStyle = TRUST_TIER_STYLES[module.trust_tier] || TRUST_TIER_STYLES.community;

  return (
    <button
      type="button"
      onClick={onClick}
      className="text-left p-4 rounded-lg border border-theme-border-default bg-theme-bg-card hover:bg-theme-bg-hover transition-colors"
    >
      <div className="flex justify-between items-start mb-2">
        <h3 className="font-semibold text-theme-text-primary">{module.name}</h3>
        <span className={`text-xs px-2 py-0.5 rounded border ${tierStyle}`}>
          {module.trust_tier}
        </span>
      </div>

      {module.description && (
        <p className="text-sm text-theme-text-secondary mb-3 line-clamp-2">{module.description}</p>
      )}

      <div className="flex items-center justify-between text-xs text-theme-text-muted">
        <span>v{module.current_version_number}</span>
        <span>{module.assignment_count} node{module.assignment_count === 1 ? '' : 's'}</span>
        {module.platform && <span>{module.platform}</span>}
      </div>
    </button>
  );
};
