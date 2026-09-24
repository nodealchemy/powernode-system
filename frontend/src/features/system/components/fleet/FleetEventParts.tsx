import React from 'react';
import { Link } from 'react-router-dom';
import { Package } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { EntityLink } from '@/shared/components/entity';
import type { FleetEvent } from '@system/features/system/services/api/fleetApi';

// One fleet event, rendered the same way wherever it appears: the Fleet
// Dashboard's signal stream and the component status drawer's per-component
// signals view (SignalsDrawerView). Lifted out of FleetDashboardPage so the
// drawer reuses the row and detail rather than growing a second rendering of
// the same noun.

export function SeverityBadge({ severity }: { severity: FleetEvent['severity'] }): React.JSX.Element {
  const variant = severity === 'critical' || severity === 'high' ? 'danger' : severity === 'medium' ? 'warning' : 'default';
  return <Badge variant={variant}>{severity}</Badge>;
}

interface FleetEventRowProps {
  event: FleetEvent;
  selected?: boolean;
  onSelect: (event: FleetEvent) => void;
}

export function FleetEventRow({ event: e, selected = false, onSelect }: FleetEventRowProps): React.JSX.Element {
  return (
    <li
      className={`px-4 py-2 hover:bg-theme-surface-hover cursor-pointer ${selected ? 'bg-theme-surface-hover' : ''}`}
      onClick={() => onSelect(e)}
    >
      <div className="flex items-center justify-between gap-2">
        <div className="font-mono text-xs flex-1 truncate">{e.kind}</div>
        <SeverityBadge severity={e.severity} />
        <span className="text-xs text-theme-tertiary">
          {new Date(e.emitted_at).toLocaleTimeString()}
        </span>
      </div>
      <div className="flex items-center gap-3 mt-0.5 text-xs text-theme-tertiary">
        {e.source && <span>source: {e.source}</span>}
        {/* When an event references a specific module (e.g.
            system.module_published), give the operator one-
            click navigation to that module's detail page. */}
        {e.node_module_id && (
          <Link
            to={`/app/system/catalog/modules?module_id=${e.node_module_id}`}
            onClick={(ev) => ev.stopPropagation()}
            className="inline-flex items-center gap-1 text-theme-link hover:underline"
            title="View module"
          >
            <Package size={12} />
            {(e.payload?.module_name as string | undefined) ?? 'view module'}
          </Link>
        )}
      </div>
    </li>
  );
}

interface FleetEventDetailProps {
  event: FleetEvent;
  /** Surface-specific actions rendered under the payload (the dashboard adds attribution feedback and boot replay). */
  children?: React.ReactNode;
}

export function FleetEventDetail({ event, children }: FleetEventDetailProps): React.JSX.Element {
  return (
    <div className="px-4 py-3 border-b border-theme space-y-2">
      <div className="flex items-center gap-2">
        <span className="font-mono text-xs">{event.kind}</span>
        <SeverityBadge severity={event.severity} />
      </div>
      <div className="text-xs text-theme-tertiary space-y-0.5">
        <div>id: <code className="font-mono">{event.id}</code></div>
        <div>emitted: {new Date(event.emitted_at).toLocaleString()}</div>
        {event.source && <div>source: {event.source}</div>}
        {event.correlation_id && (
          <div>correlation_id: <code className="font-mono">{event.correlation_id}</code></div>
        )}
        {event.node_id && (
          <div>
            node_id:{' '}
            <EntityLink type="node" id={event.node_id} label={event.node_id} className="font-mono" />
          </div>
        )}
        {event.node_instance_id && (
          <div>
            instance_id:{' '}
            {event.node_id ? (
              <EntityLink
                type="node_instance"
                id={`${event.node_id}:${event.node_instance_id}`}
                label={event.node_instance_id}
                className="font-mono"
              />
            ) : (
              <code className="font-mono">{event.node_instance_id}</code>
            )}
          </div>
        )}
        {event.node_module_id && (
          <div>
            module_id:{' '}
            <EntityLink type="node_module" id={event.node_module_id} label={event.node_module_id} className="font-mono" />
          </div>
        )}
        {event.certificate_id && (
          <div>certificate_id: <code className="font-mono">{event.certificate_id}</code></div>
        )}
      </div>
      {event.payload && Object.keys(event.payload).length > 0 && (
        <details className="text-xs" open>
          <summary className="cursor-pointer text-theme-tertiary hover:text-theme-primary">payload</summary>
          <pre className="mt-1 p-2 bg-theme-surface rounded text-xs overflow-x-auto font-mono">
{JSON.stringify(event.payload, null, 2)}
          </pre>
        </details>
      )}
      {children}
    </div>
  );
}
