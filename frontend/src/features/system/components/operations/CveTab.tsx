import React, { useCallback, useEffect, useState } from 'react';
import { ShieldAlert } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { cveApi } from '@system/features/system/services/api/cveApi';
import type {
  SystemCveExposure,
  SystemCveExposureState,
} from '@system/features/system/types/system.types';

interface CveTabProps {
  onActionsReady?: (handle: { refresh: () => void } | null) => void;
}

// Severity → Badge variant. The Badge component maps these to theme classes
// (danger → bg-theme-error, warning → bg-theme-warning, info → bg-theme-info),
// so colors stay theme-driven — never hardcoded.
function severityVariant(severity?: string | null): 'danger' | 'warning' | 'info' | 'secondary' {
  switch ((severity ?? '').toLowerCase()) {
    case 'critical':
    case 'high':
      return 'danger';
    case 'medium':
      return 'warning';
    case 'low':
      return 'info';
    default:
      return 'secondary';
  }
}

function stateVariant(state: SystemCveExposureState): 'danger' | 'warning' | 'success' | 'secondary' {
  switch (state) {
    case 'open':
      return 'danger';
    case 'remediating':
      return 'warning';
    case 'resolved':
      return 'success';
    case 'wont_fix':
    default:
      return 'secondary';
  }
}

const STATE_LABELS: Record<SystemCveExposureState, string> = {
  open: 'Open',
  remediating: 'Remediating',
  resolved: 'Resolved',
  wont_fix: "Won't fix",
};

const SEVERITY_FILTERS = ['critical', 'high', 'medium', 'low'] as const;

export const CveTab: React.FC<CveTabProps> = ({ onActionsReady }) => {
  const { addNotification } = useNotifications();

  const [exposures, setExposures] = useState<SystemCveExposure[]>([]);
  const [loading, setLoading] = useState(true);
  const [severityFilter, setSeverityFilter] = useState<string>('');

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await cveApi.list(
        severityFilter ? { severity: severityFilter } : undefined
      );
      setExposures(result.cve_exposures);
    } catch {
      addNotification({ type: 'error', message: 'Failed to load CVE exposures' });
    } finally {
      setLoading(false);
    }
  }, [addNotification, severityFilter]);

  useEffect(() => { void refresh(); }, [refresh]);

  useEffect(() => {
    onActionsReady?.({ refresh: () => void refresh() });
    return () => onActionsReady?.(null);
  }, [onActionsReady, refresh]);

  return (
    <div className="space-y-4">
      <p className="text-sm text-theme-secondary">
        CVE exposures bind a published vulnerability to a specific module
        version in your fleet. The CVE Responder agent ingests the feed,
        scans module SBOMs, and orchestrates remediation (rebuild + rolling
        upgrade) — this view is read-only. Filter by severity to triage the
        fleet&apos;s risk posture.
      </p>

      <div className="flex items-center gap-2 flex-wrap">
        <span className="text-xs text-theme-tertiary">Severity:</span>
        <button
          type="button"
          onClick={() => setSeverityFilter('')}
          className={
            'px-2.5 py-1 text-xs rounded-full border transition-colors ' +
            (severityFilter === ''
              ? 'border-theme-focus text-theme-primary'
              : 'border-theme text-theme-secondary hover:text-theme-primary')
          }
        >
          All
        </button>
        {SEVERITY_FILTERS.map((sev) => (
          <button
            key={sev}
            type="button"
            onClick={() => setSeverityFilter(sev)}
            className={
              'px-2.5 py-1 text-xs rounded-full border capitalize transition-colors ' +
              (severityFilter === sev
                ? 'border-theme-focus text-theme-primary'
                : 'border-theme text-theme-secondary hover:text-theme-primary')
            }
          >
            {sev}
          </button>
        ))}
      </div>

      <section className="bg-theme-surface rounded-lg border border-theme">
        <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
          <ShieldAlert size={16} className="text-theme-warning" />
          <h2 className="font-medium text-theme-primary">CVE exposures</h2>
          {exposures.length > 0 && (
            <Badge variant="info" size="xs">{exposures.length}</Badge>
          )}
        </header>
        <div className="p-2">
          {loading ? (
            <p className="text-sm text-theme-tertiary p-3">Loading…</p>
          ) : exposures.length === 0 ? (
            <p className="text-sm text-theme-secondary p-3">
              {severityFilter
                ? `No ${severityFilter} CVE exposures in your fleet.`
                : 'No CVE exposures detected in your fleet.'}
            </p>
          ) : (
            <ul className="divide-y divide-theme">
              {exposures.map((e) => (
                <li key={e.id} className="px-3 py-2.5">
                  <div className="flex items-start justify-between gap-3">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 text-sm flex-wrap">
                        {e.cve && (
                          <Badge variant={severityVariant(e.cve.severity)} size="xs">
                            {e.cve.severity}
                          </Badge>
                        )}
                        <span className="font-medium text-theme-primary">
                          {e.cve?.cve_id ?? 'Unknown CVE'}
                        </span>
                        <Badge variant={stateVariant(e.state)} size="xs">
                          {STATE_LABELS[e.state] ?? e.state}
                        </Badge>
                      </div>
                      {e.cve?.summary && (
                        <div className="mt-1 text-xs text-theme-secondary line-clamp-2">
                          {e.cve.summary}
                        </div>
                      )}
                      <div className="mt-1 text-xs text-theme-tertiary">
                        <code className="text-xs">
                          {e.package_name}
                          {e.package_version ? `@${e.package_version}` : ''}
                        </code>
                        {e.node_module && (
                          <>
                            <span className="mx-1">·</span>
                            <span>{e.node_module.name}</span>
                          </>
                        )}
                        {e.node_module_version && (
                          <>
                            <span className="mx-1">·</span>
                            <span>v{e.node_module_version.version_number}</span>
                          </>
                        )}
                      </div>
                      <div className="mt-0.5 text-xs text-theme-tertiary">
                        {e.detected_at
                          ? <>Detected {new Date(e.detected_at).toLocaleString()}</>
                          : 'Detection time unknown'}
                        {e.resolved_at && (
                          <> · Resolved {new Date(e.resolved_at).toLocaleString()}</>
                        )}
                      </div>
                    </div>
                    {e.cve?.reference_url && (
                      <a
                        href={e.cve.reference_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-xs text-theme-info hover:underline whitespace-nowrap shrink-0"
                      >
                        Reference
                      </a>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </section>
    </div>
  );
};
