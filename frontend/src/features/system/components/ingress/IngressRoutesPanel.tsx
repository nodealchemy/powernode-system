import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Globe,
  AlertTriangle,
  X,
  RefreshCw,
  Clock,
  ShieldAlert,
  CheckCircle2,
  ChevronRight,
  ChevronDown,
  ExternalLink,
} from 'lucide-react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { logger } from '@/shared/utils/logger';
import { ingressApi } from '../../services/api/ingressApi';
import type { IngressRoute, IngressRouteStatus } from '../../services/api/ingressApi';
import { InfiniteScrollSentinel } from '../shared/InfiniteScrollSentinel';

/**
 * Routes tab — read-only monitor list of the ingress routes the platform
 * derives from issued ACME certificates. Each row maps to one cert and shows
 * its host matcher, lifecycle status, issuer, and expiry. Expanding a row
 * reveals the derived Traefik routers (path_prefix -> backend_service:backend_url).
 *
 * The list itself is fetched in one shot (the server returns all routes); the
 * panel reveals them progressively via the shared InfiniteScrollSentinel so the
 * surface follows the platform's infinite-scroll convention rather than
 * Previous/Next pagination.
 *
 * Permission gate: system.ingress.read.
 *
 * Plan reference: Phase 2c (Ingress).
 */

// Page size for client-side progressive reveal. The server returns the full
// set; we slice it so the DOM stays light and the sentinel can page in more.
const PAGE_SIZE = 25;

export const IngressRoutesPanel: React.FC = () => {
  const { hasPermission } = usePermissions();
  const canRead = hasPermission('system.ingress.read');

  const [routes, setRoutes] = useState<IngressRoute[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE);

  const fetchRoutes = useCallback(async () => {
    if (!canRead) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const result = await ingressApi.listRoutes();
      setRoutes(result);
      setVisibleCount(PAGE_SIZE);
    } catch (err: unknown) {
      logger.error('[IngressRoutesPanel] failed to load routes', err);
      setError(err instanceof Error ? err.message : 'Failed to load ingress routes');
    } finally {
      setLoading(false);
    }
  }, [canRead]);

  useEffect(() => {
    void fetchRoutes();
  }, [fetchRoutes]);

  const visibleRoutes = useMemo(
    () => routes.slice(0, visibleCount),
    [routes, visibleCount],
  );
  const hasMore = visibleCount < routes.length;

  const loadMore = useCallback(() => {
    setVisibleCount((c) => Math.min(c + PAGE_SIZE, routes.length));
  }, [routes.length]);

  if (!canRead) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        You don't have permission to view ingress routes. Ask an admin to grant
        <code className="mx-1 font-mono">system.ingress.read</code>.
      </div>
    );
  }

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
        <Globe className="w-5 h-5 text-theme-info" />
        <h2 className="font-semibold text-theme-primary">Routes</h2>
        <span className="text-xs text-theme-secondary">
          {loading
            ? 'loading…'
            : `${routes.length} ${routes.length === 1 ? 'route' : 'routes'}`}
        </span>
        <button
          type="button"
          onClick={() => void fetchRoutes()}
          disabled={loading}
          title="Refresh"
          className="ml-auto p-1.5 rounded text-theme-secondary hover:bg-theme-surface-hover disabled:opacity-40 transition-colors"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger text-theme-danger flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button type="button" onClick={() => setError(null)} className="p-1">
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      {!loading && routes.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm">
          No ingress routes yet. Routes are derived from issued certificates — request a
          certificate under ACME, or use the Expose Service tab to publish a service publicly.
        </div>
      )}

      {visibleRoutes.length > 0 && (
        <ul className="divide-y divide-theme" data-testid="ingress-routes-list">
          {visibleRoutes.map((route) => (
            <RouteRow key={route.id} route={route} />
          ))}
        </ul>
      )}

      <InfiniteScrollSentinel onIntersect={loadMore} enabled={hasMore && !loading} />
      {!hasMore && routes.length > PAGE_SIZE && (
        <p className="text-center text-sm text-theme-tertiary py-2">All {routes.length} loaded</p>
      )}
    </div>
  );
};

interface RouteRowProps {
  route: IngressRoute;
}

const RouteRow: React.FC<RouteRowProps> = ({ route }) => {
  const [expanded, setExpanded] = useState(false);

  return (
    <li className="px-4 py-3" data-testid="ingress-route-row">
      <button
        type="button"
        onClick={() => setExpanded((e) => !e)}
        className="w-full flex items-start gap-3 text-left"
        aria-expanded={expanded}
      >
        <span className="mt-0.5 text-theme-tertiary">
          {expanded ? <ChevronDown className="w-4 h-4" /> : <ChevronRight className="w-4 h-4" />}
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-theme-primary font-mono text-xs break-all">
              {route.host_rule}
            </span>
            <StatusPill status={route.status} />
          </div>
          <div className="mt-1 flex items-center gap-3 flex-wrap text-xs text-theme-secondary">
            <span className="font-mono">{route.common_name}</span>
            {route.sans.length > 0 && (
              <span>
                +{route.sans.length} SAN{route.sans.length === 1 ? '' : 's'}
              </span>
            )}
            <span>
              issuer:{' '}
              <span className="font-mono text-theme-tertiary">{route.issuer ?? '—'}</span>
            </span>
            <span className="inline-flex items-center gap-1">
              {route.routers.length} router{route.routers.length === 1 ? '' : 's'}
            </span>
          </div>
        </div>
        <div className="text-right text-xs text-theme-secondary flex-shrink-0">
          {route.expires_at ? (
            <>
              <div>{new Date(route.expires_at).toLocaleDateString()}</div>
              {route.days_until_expiry !== null && (
                <div
                  className={
                    route.days_until_expiry < 30 ? 'text-theme-warning' : 'text-theme-tertiary'
                  }
                >
                  {route.days_until_expiry > 0
                    ? `in ${route.days_until_expiry}d`
                    : `expired ${Math.abs(route.days_until_expiry)}d ago`}
                </div>
              )}
            </>
          ) : (
            <span className="text-theme-tertiary">no expiry</span>
          )}
        </div>
      </button>

      {expanded && (
        <div className="mt-3 ml-7 space-y-3">
          {route.public_endpoints.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {route.public_endpoints.map((url) => (
                <a
                  key={url}
                  href={url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-xs px-2 py-1 rounded-md bg-theme-surface border border-theme text-theme-info hover:bg-theme-surface-hover transition-colors"
                >
                  <ExternalLink className="w-3 h-3" />
                  <span className="font-mono break-all">{url}</span>
                </a>
              ))}
            </div>
          )}

          <div className="border border-theme rounded-md overflow-hidden">
            <table className="w-full text-xs">
              <thead className="bg-theme-background-secondary text-theme-secondary uppercase">
                <tr>
                  <th className="text-left px-3 py-1.5 font-medium">Router</th>
                  <th className="text-left px-3 py-1.5 font-medium">Path prefix</th>
                  <th className="text-left px-3 py-1.5 font-medium">Backend</th>
                  <th className="text-left px-3 py-1.5 font-medium">Entrypoint</th>
                </tr>
              </thead>
              <tbody>
                {route.routers.map((router) => (
                  <tr key={router.name} className="border-t border-theme">
                    <td className="px-3 py-1.5 font-mono text-theme-primary break-all">
                      {router.name}
                    </td>
                    <td className="px-3 py-1.5 font-mono text-theme-secondary">
                      {router.path_prefix && router.path_prefix !== '/' ? router.path_prefix : '/'}
                    </td>
                    <td className="px-3 py-1.5 font-mono text-theme-secondary break-all">
                      {router.backend_service}
                      <span className="text-theme-tertiary"> → {router.backend_url}</span>
                    </td>
                    <td className="px-3 py-1.5 font-mono text-theme-tertiary">
                      {router.entrypoint}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </li>
  );
};

const StatusPill: React.FC<{ status: IngressRouteStatus }> = ({ status }) => {
  const config: Record<
    IngressRouteStatus,
    { className: string; icon: React.ReactNode; label: string }
  > = {
    valid: {
      className: 'bg-theme-success text-theme-success',
      icon: <CheckCircle2 className="w-3 h-3" />,
      label: 'valid',
    },
    pending: {
      className: 'bg-theme-warning text-theme-warning',
      icon: <Clock className="w-3 h-3" />,
      label: 'pending',
    },
    issuing: {
      className: 'bg-theme-warning text-theme-warning',
      icon: <RefreshCw className="w-3 h-3 animate-spin" />,
      label: 'issuing',
    },
    renewing: {
      className: 'bg-theme-warning text-theme-warning',
      icon: <RefreshCw className="w-3 h-3 animate-spin" />,
      label: 'renewing',
    },
    revoked: {
      className: 'bg-theme-danger text-theme-danger',
      icon: <ShieldAlert className="w-3 h-3" />,
      label: 'revoked',
    },
  };
  const c = config[status];
  return (
    <span
      className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium ${c.className}`}
    >
      {c.icon}
      {c.label}
    </span>
  );
};

export default IngressRoutesPanel;
