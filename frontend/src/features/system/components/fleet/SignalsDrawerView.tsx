import { FC, useEffect, useState } from 'react';
import { Radio } from 'lucide-react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import ErrorAlert from '@/shared/components/ui/ErrorAlert';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { EmptyState } from '@/shared/components/ui/EmptyState';
import type { ComponentStatusDetail } from '@/shared/types/platformStatus';
import { fleetApi, type FleetEvent } from '@system/features/system/services/api/fleetApi';
import { FleetEventDetail, FleetEventRow } from './FleetEventParts';
import { SIGNAL_FILTER_COLUMN_BY_KIND, isSignalsKind } from './signalsFilterColumns';

/** Newest-first page size — the same cap the signals endpoint defaults to. */
export const SIGNALS_LIMIT = 50;

type SignalsParams = NonNullable<Parameters<typeof fleetApi.recentSignals>[0]>;

interface SignalsDrawerViewProps {
  row: ComponentStatusDetail;
}

/**
 * The component status drawer's signals view, registered at
 * `platform.status.drawer.<kind>.signals` for every kind in
 * SIGNAL_FILTER_COLUMN_BY_KIND (design §6, signals ruling).
 *
 * Signals are a different noun from component status: this lists the recent
 * fleet events recorded AGAINST this component, by the event's typed column
 * (node_instance_id, node_module_id or certificate_id), and never by matching
 * payload keys. The row and detail are the Fleet Dashboard's own
 * (FleetEventParts), so one event reads the same in both places.
 *
 * Gated inline on system.fleet.read, the permission the signals endpoint
 * checks, with a refusal that names it (the boot-replay view's ruling). No
 * nested Modal: the drawer already is one.
 */
export const SignalsDrawerView: FC<SignalsDrawerViewProps> = ({ row }) => {
  const { hasPermission } = usePermissions();
  const allowed = hasPermission('system.fleet.read');
  const column = isSignalsKind(row.component_kind) ? SIGNAL_FILTER_COLUMN_BY_KIND[row.component_kind] : null;
  const componentRef = row.component_ref;

  const [events, setEvents] = useState<FleetEvent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<FleetEvent | null>(null);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (!allowed || !column) return undefined;

    // A response for a component the drawer has since left must not land on
    // the one it shows now.
    let current = true;
    setEvents(null);
    setError(null);
    setSelected(null);

    const params: SignalsParams = { limit: SIGNALS_LIMIT };
    params[column] = componentRef;
    fleetApi
      .recentSignals(params)
      .then((result) => {
        if (current) setEvents(result.events);
      })
      .catch((err: unknown) => {
        if (current) setError(err instanceof Error ? err.message : 'Failed to load signals');
      });

    return () => {
      current = false;
    };
  }, [allowed, column, componentRef, attempt]);

  if (!allowed) {
    return (
      <div className="p-4 text-sm text-theme-tertiary">
        You don&apos;t have permission to view signals.
        Required: <code>system.fleet.read</code>
      </div>
    );
  }

  if (!column) {
    return (
      <div className="p-4 text-sm text-theme-tertiary">
        Signals are not recorded per component for this kind.
      </div>
    );
  }

  if (error) {
    return (
      <div className="p-4 space-y-2">
        <ErrorAlert message={error} />
        <button
          type="button"
          onClick={() => setAttempt((n) => n + 1)}
          className="text-xs text-theme-link hover:underline"
        >
          Retry
        </button>
      </div>
    );
  }

  if (events === null) {
    return <LoadingSpinner size="sm" message="Loading signals…" className="p-4" />;
  }

  if (events.length === 0) {
    return (
      <EmptyState
        icon={Radio}
        title="No signals"
        description={`No recent fleet event records this component by ${column}.`}
      />
    );
  }

  return (
    <div className="text-sm">
      <p className="px-4 py-2 text-xs text-theme-tertiary">
        The {events.length} most recent fleet events whose {column} is this component
        (newest first, at most {SIGNALS_LIMIT}).
      </p>
      <ul className="divide-y divide-theme-border">
        {events.map((e) => (
          <FleetEventRow key={e.id} event={e} selected={selected?.id === e.id} onSelect={setSelected} />
        ))}
      </ul>
      {selected && <FleetEventDetail event={selected} />}
    </div>
  );
};

export default SignalsDrawerView;
