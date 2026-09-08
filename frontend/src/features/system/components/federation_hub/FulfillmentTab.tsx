import React, { useCallback, useEffect, useState } from 'react';
import {
  ClipboardCheck,
  AlertTriangle,
  X,
  RefreshCw,
  CheckCircle2,
  Clock,
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import { apiErrorMessage, isPendingApproval } from '../../services/api/helpers';
import { serviceCatalogApi } from '../../services/api/serviceCatalogApi';
import type {
  FulfillmentRequestDetail,
  FulfillmentRequestState,
  FulfillmentRequestSummary,
} from '../../types/service_delivery.types';

/**
 * Capability fulfillment — the operator's approval surface (IMP-3fd7f5c67a7b).
 *
 * `composed` is the one state the 60s FulfillmentRequestSweepService will not
 * advance: it is excluded from ADVANCEABLE_STATES because that edge waits on a
 * human, not on the orchestrator. Approve stamped source "operator_ui" while no
 * operator UI existed, so a composed request hung there indefinitely.
 *
 * The frozen-plan contract is what shapes this tab: approve releases
 * plan["execution"] verbatim, never re-composing or re-resolving. So the
 * confirmation shows the plan being released — including the unresolved gaps
 * and parks the executor recorded — rather than asking for a blind yes.
 *
 * Plan reference: campaign 019f6084 inc-M.
 */

const STATE_VARIANT: Record<
  FulfillmentRequestState,
  'default' | 'success' | 'warning' | 'danger' | 'info'
> = {
  composed: 'warning',
  approved: 'info',
  materializing: 'info',
  building: 'info',
  templated: 'info',
  provisioning: 'info',
  smoking: 'info',
  ready: 'success',
  failed: 'danger',
  expired: 'default',
};

/** Renders the frozen plan for the confirmation body. */
const PlanSummary: React.FC<{ detail: FulfillmentRequestDetail }> = ({ detail }) => {
  const execution = detail.plan?.execution ?? {};
  const gaps = detail.plan?.unresolved_gaps ?? [];
  const parks = detail.parked ?? [];

  return (
    <div className="space-y-3 text-sm text-theme-primary">
      <p>
        Approving releases this plan <strong>as-is</strong>. It is not re-composed
        and nothing below is re-resolved at execution time.
      </p>

      <dl className="space-y-1 text-xs">
        <div className="flex gap-2">
          <dt className="text-theme-secondary w-32 flex-shrink-0">Request</dt>
          <dd className="text-theme-primary break-words">{detail.request}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-theme-secondary w-32 flex-shrink-0">Template</dt>
          <dd className="font-mono">{execution.template_name ?? '—'}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-theme-secondary w-32 flex-shrink-0">Base OS module</dt>
          <dd className="font-mono break-all">{execution.base_os_module_id ?? '—'}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-theme-secondary w-32 flex-shrink-0">Reused modules</dt>
          <dd>{execution.reused_module_ids?.length ?? 0}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-theme-secondary w-32 flex-shrink-0">Modules to build</dt>
          <dd>{execution.gaps?.length ?? 0}</dd>
        </div>
        <div className="flex gap-2">
          <dt className="text-theme-secondary w-32 flex-shrink-0">Plan digest</dt>
          <dd className="font-mono text-theme-secondary break-all">{detail.plan_digest}</dd>
        </div>
      </dl>

      {gaps.length > 0 && (
        <div className="p-2 bg-theme-warning-bg text-theme-warning-fg rounded text-xs">
          <p className="font-medium">
            {gaps.length} {gaps.length === 1 ? 'capability' : 'capabilities'} could not
            be resolved and will NOT be delivered:
          </p>
          <ul className="list-disc pl-5 mt-1 space-y-0.5">
            {gaps.map((gap, i) => (
              <li key={i}>
                <span className="font-mono">{gap.capability ?? 'unknown'}</span>
                {gap.reason ? ` — ${gap.reason}` : ''}
              </li>
            ))}
          </ul>
        </div>
      )}

      {parks.length > 0 && (
        <div className="p-2 bg-theme-warning-bg text-theme-warning-fg rounded text-xs">
          <p className="font-medium">
            {parks.length} park{parks.length === 1 ? '' : 's'} recorded before this
            reached you:
          </p>
          <ul className="list-disc pl-5 mt-1 space-y-0.5">
            {parks.map((park, i) => (
              <li key={i}>{park.reason ?? JSON.stringify(park)}</li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
};

export const FulfillmentTab: React.FC = () => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const { confirm, ConfirmationDialog } = useConfirmation();
  const canApprove = hasPermission('system.fulfillment_requests.approve');

  const [requests, setRequests] = useState<FulfillmentRequestSummary[]>([]);
  const [awaitingCount, setAwaitingCount] = useState(0);
  // The index paginates. `awaiting_approval_count` counts EVERY composed row,
  // so on a busy account the badge can exceed what this page shows — and an
  // unlisted composed request is an unapprovable one, which is the hang this
  // tab exists to end. Say so rather than letting the two numbers disagree
  // silently.
  const shownComposed = requests.filter((r) => r.state === 'composed').length;
  const hiddenComposed = Math.max(awaitingCount - shownComposed, 0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const fetchRequests = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await serviceCatalogApi.listFulfillmentRequests();
      setRequests(result.fulfillment_requests);
      setAwaitingCount(result.awaiting_approval_count);
    } catch (err: unknown) {
      setError(apiErrorMessage(err, 'Failed to load fulfillment requests'));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void fetchRequests();
  }, [fetchRequests, refreshKey]);

  // Fetch the frozen plan BEFORE opening the dialog: the operator is approving
  // those bytes, so showing a spinner in place of them would defeat the point.
  const handleApproveClick = async (row: FulfillmentRequestSummary) => {
    setBusyId(row.id);
    let detail: FulfillmentRequestDetail;
    try {
      detail = await serviceCatalogApi.getFulfillmentRequest(row.id);
    } catch (err: unknown) {
      setError(apiErrorMessage(err, 'Failed to load the plan for this request'));
      setBusyId(null);
      return;
    }
    setBusyId(null);

    confirm({
      title: 'Approve this fulfillment request?',
      message: <PlanSummary detail={detail} />,
      confirmLabel: 'Approve and release the plan',
      variant: 'warning',
      onConfirm: async () => {
        setBusyId(row.id);
        try {
          const result = await serviceCatalogApi.approveFulfillment(row.id);
          if (isPendingApproval(result)) {
            addNotification({
              type: 'info',
              message: result.message || 'Approval is parked awaiting a second approval.',
            });
          } else if (result.advance.error || result.advance.ok === false) {
            // park_gate! (the budget + rate-limit gate) ALWAYS sets `error`
            // alongside the park, so `error` is the gate signal. `parked` is a
            // cumulative trail that add_park! appends to and never clears — a
            // request queued because autonomous approval was withheld already
            // carries a park before the operator ever sees it, so branching on
            // a non-empty trail would warn on every successful approval and
            // still miss the gate. The ok===false arm catches a failure that
            // ever arrives without a sentence rather than calling it success.
            addNotification({
              type: 'warning',
              message: result.advance.error
                ? `Approved, but the first advance reported: ${result.advance.error}`
                : `Approved, but the first advance did not complete (now ${result.advance.state}).`,
            });
          } else {
            addNotification({
              type: 'success',
              message: `Approved. Now ${result.advance.state}; the sweep carries it from here.`,
            });
          }
          setRefreshKey((k) => k + 1);
        } catch (err: unknown) {
          addNotification({
            type: 'error',
            message: apiErrorMessage(err, 'Approve failed'),
          });
        } finally {
          setBusyId(null);
        }
      },
    });
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
      <header className="px-4 py-3 border-b border-theme flex items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <ClipboardCheck className="w-5 h-5 text-theme-info-fg" />
          <h2 className="font-semibold text-theme-primary">Capability Fulfillment</h2>
          {!loading && awaitingCount > 0 && (
            <Badge variant="warning">
              {awaitingCount} awaiting approval
            </Badge>
          )}
          {!loading && hiddenComposed > 0 && (
            <span className="text-xs text-theme-warning-fg">
              {hiddenComposed} not shown on this page
            </span>
          )}
          <span className="text-xs text-theme-secondary">
            {loading
              ? 'loading…'
              : `${requests.length} request${requests.length === 1 ? '' : 's'}`}
          </span>
        </div>
        <button
          type="button"
          onClick={() => setRefreshKey((k) => k + 1)}
          disabled={loading}
          className="p-1.5 rounded text-theme-secondary hover:text-theme-primary hover:bg-theme-surface-hover transition-colors disabled:opacity-40"
          title="Refresh"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </header>

      {error && (
        <div className="p-3 bg-theme-danger-bg text-theme-danger-fg flex items-center gap-2 text-sm">
          <AlertTriangle className="w-4 h-4 flex-shrink-0" />
          <span className="flex-1">{error}</span>
          <button
            type="button"
            onClick={() => setError(null)}
            className="p-1"
            aria-label="Dismiss error"
          >
            <X className="w-3 h-3" />
          </button>
        </div>
      )}

      {!loading && requests.length === 0 && !error && (
        <div className="p-12 text-center text-theme-secondary text-sm space-y-2">
          <div>No fulfillment requests.</div>
          <div className="text-xs text-theme-tertiary max-w-2xl mx-auto">
            A capability request composes a plan and then waits here for a human to
            release it. Everything after that is driven by the worker sweep.
          </div>
        </div>
      )}

      {requests.length > 0 && (
        <table className="w-full text-sm">
          <thead className="bg-theme-background-secondary text-xs text-theme-secondary uppercase">
            <tr>
              <th className="text-left px-4 py-2 font-medium">Request</th>
              <th className="text-left px-4 py-2 font-medium">State</th>
              <th className="text-left px-4 py-2 font-medium">Modules</th>
              <th className="text-left px-4 py-2 font-medium">Created</th>
              <th className="text-right px-4 py-2 font-medium">Actions</th>
            </tr>
          </thead>
          <tbody>
            {requests.map((row) => (
              <tr key={row.id} className="border-t border-theme">
                <td className="px-4 py-2 text-theme-primary max-w-md">
                  <span className="break-words">{row.request}</span>
                </td>
                <td className="px-4 py-2">
                  <Badge variant={STATE_VARIANT[row.state] ?? 'default'}>{row.state}</Badge>
                </td>
                <td className="px-4 py-2 text-theme-secondary text-xs">
                  {row.reused_count} reused · {row.materialized_count} built
                </td>
                <td className="px-4 py-2 text-theme-secondary text-xs">
                  <span className="inline-flex items-center gap-1">
                    <Clock className="w-3 h-3" />
                    {new Date(row.created_at).toLocaleString()}
                  </span>
                </td>
                <td className="px-4 py-2 text-right">
                  {row.state === 'composed' && canApprove && (
                    <Button
                      variant="primary"
                      size="sm"
                      onClick={() => void handleApproveClick(row)}
                      disabled={busyId === row.id}
                    >
                      <CheckCircle2 className="w-3.5 h-3.5 mr-1" />
                      {busyId === row.id ? 'Working…' : 'Approve'}
                    </Button>
                  )}
                  {row.state === 'composed' && !canApprove && (
                    <span className="text-xs text-theme-secondary italic">
                      awaiting an approver
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {ConfirmationDialog}
    </div>
  );
};
