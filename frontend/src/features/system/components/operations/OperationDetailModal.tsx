import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  X,
  Activity,
  Clock,
  CheckCircle,
  XCircle,
  AlertCircle,
  User,
  Server,
  Calendar,
  Ban,
  StopCircle,
  RefreshCw
} from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { EntityLink } from '@/shared/components/entity';
import { systemApi } from '@system/features/system/services/systemApi';
import { resolveOperableType } from '@system/features/system/entityRegistry';
import { useSystemWebSocket } from '@system/features/system/hooks/useSystemWebSocket';
import { useReasonConfirm } from '@system/features/system/hooks/useReasonConfirm';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import type { SystemTask } from '@system/features/system/types/system.types';

interface OperationDetailModalProps {
  operationId: string | null;
  isOpen: boolean;
  onClose: () => void;
  onOperationUpdated?: () => void;
}

type TabId = 'info' | 'events' | 'options';

const statusLabels: Record<string, string> = {
  pending: 'Pending',
  scheduled: 'Scheduled',
  running: 'Running',
  complete: 'Complete',
  failed: 'Failed',
  aborted: 'Aborted',
  cancelled: 'Cancelled'
};

// Statuses a task can still move on from. Anything else is terminal, so there
// is nothing left to watch for.
const ACTIVE_STATUSES = [ 'pending', 'scheduled', 'running' ];

// Fallback refresh cadence, used only while the SystemChannel socket is down.
const POLL_INTERVAL_MS = 5000;

const statusColors: Record<string, 'info' | 'success' | 'warning' | 'danger' | 'secondary' | 'primary'> = {
  pending: 'warning',
  scheduled: 'info',
  running: 'primary',
  complete: 'success',
  failed: 'danger',
  aborted: 'secondary',
  cancelled: 'secondary'
};

/**
 * OperationDetailModal - Modal for viewing operation details with event timeline
 */
export const OperationDetailModal: React.FC<OperationDetailModalProps> = ({
  operationId,
  isOpen,
  onClose,
  onOperationUpdated
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  // The reason field, its snapshot-safe state and the reset between dialogs all
  // live in the shared hook — six other operator panels capture a reason the
  // same way (IMP-abe28a971830).
  const { confirmWithReason, ConfirmationDialog } = useReasonConfirm();
  // The operation currently on screen. `onConfirm` is a closure captured when
  // the dialog opened, so reading the `operationId` prop from inside it yields
  // the value from THAT render, not the current one — a ref is what makes the
  // stale-target check in runStopAction actually compare two different things.
  const currentOperationIdRef = useRef(operationId);
  // Monotonic fetch token. The poll makes concurrent and out-of-order GETs
  // routine, so every response checks that it is still the newest one before
  // it writes: otherwise a slow response for the previous operation lands on
  // top of the current one, and a poll issued just before an abort reverts the
  // status the abort's own refresh had already applied.
  const fetchSeqRef = useRef(0);
  const [operation, setOperation] = useState<SystemTask | null>(null);
  const [loading, setLoading] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>('info');
  const [actionLoading, setActionLoading] = useState<string | null>(null);

  // Permission checks
  const canControlOperations = hasPermission('system.infra_tasks.control');

  useEffect(() => {
    currentOperationIdRef.current = operationId;
  }, [operationId]);

  // The initial load, extracted so the error branch can re-run it. A failed
  // first load leaves `operation` null, and the live refresh below is keyed on
  // the loaded status, so nothing ever retries on its own: a transient 502
  // during a deploy boot would otherwise strand the operator on a dead modal.
  const loadOperation = useCallback(() => {
    if (!operationId) return;
    const seq = ++fetchSeqRef.current;
    setLoading(true);

    systemApi.getTask(operationId)
      .then(data => {
        if (seq !== fetchSeqRef.current) return;
        setOperation(data);
      })
      .catch(() => {
        if (seq !== fetchSeqRef.current) return;
        setOperation(null);
      })
      .finally(() => {
        if (seq !== fetchSeqRef.current) return;
        setLoading(false);
      });
  }, [operationId]);

  useEffect(() => {
    if (isOpen && operationId) {
      setActiveTab('info');
      loadOperation();
    }
  }, [isOpen, operationId, loadOperation]);

  const refreshOperation = useCallback(async () => {
    if (!operationId) return;
    const seq = ++fetchSeqRef.current;
    try {
      const data = await systemApi.getTask(operationId);
      if (seq !== fetchSeqRef.current || currentOperationIdRef.current !== operationId) return;
      setOperation(data);
    } catch {
      // Silently fail refresh
    }
  }, [operationId]);

  // Live updates. System::Task#broadcast_update pushes a full task frame on
  // every status change and a throttled progress frame in between; that stream
  // is what keeps OperationList moving, so without it the drill-down an
  // operator opened from a moving row sits frozen at its opening value.
  //
  // Frames are MERGED, never substituted: SystemChannel#serialize_task_static
  // carries only the scalar columns, so replacing the loaded task with a frame
  // would blank the events timeline, the options blob, Exclusive and
  // Initiated By.
  const applyLiveUpdate = useCallback(
    (update: Partial<SystemTask> & { id?: string }) => {
      setOperation(prev => (prev && update.id === prev.id ? { ...prev, ...update } : prev));
    },
    []
  );

  // An open transport is not the same as a live feed: SystemChannel#subscribed
  // rejects an unauthorized subscription, and a rejection never reaches
  // `isConnected`. Gating the fallback on the transport alone would therefore
  // leave the modal frozen — the exact defect this fixes — in the one case
  // where no frames ever arrive. `connection_established` is transmitted only
  // on an accepted subscription, so that is what the poll defers to.
  const [liveSubscribed, setLiveSubscribed] = useState(false);

  const { isConnected: liveSocketConnected } = useSystemWebSocket({
    onConnected: () => setLiveSubscribed(true),
    onError: () => setLiveSubscribed(false),
    onOperationUpdate: (op) => applyLiveUpdate(op as unknown as Partial<SystemTask> & { id: string }),
    onOperationProgress: (p) => applyLiveUpdate({
      id: p.operation_id,
      status: p.status,
      progress: p.progress,
      description: p.description
    })
  });

  useEffect(() => {
    if (!liveSocketConnected) setLiveSubscribed(false);
  }, [liveSocketConnected]);

  const liveUpdatesActive = liveSocketConnected && liveSubscribed;

  // Fallback poll: only while the live feed is absent and the task can still move.
  const isActiveOperation = operation ? ACTIVE_STATUSES.includes(operation.status) : false;

  useEffect(() => {
    if (!isOpen || !operationId || !isActiveOperation || liveUpdatesActive) return;

    const timer = setInterval(() => { void refreshOperation(); }, POLL_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [isOpen, operationId, isActiveOperation, liveUpdatesActive, refreshOperation]);

  // Cancel (pending/scheduled) and Abort (running) are the two AASM events an
  // operator may drive from here; they differ only in which state they are
  // legal from, so they share one confirm-with-reason path.
  const runStopAction = async (action: 'cancel' | 'abort', targetId: string, reason?: string) => {
    // `targetId` is the operation the dialog was opened against. The dialog's
    // state outlives this modal's `isOpen` flag, so a confirmation left pending
    // while the operator moves to another operation must not fire at whatever
    // is on screen now.
    if (targetId !== currentOperationIdRef.current) return;
    const pastTense = action === 'cancel' ? 'cancelled' : 'aborted';

    setActionLoading(action);
    try {
      if (action === 'cancel') {
        await systemApi.cancelTask(targetId, reason);
      } else {
        await systemApi.abortTask(targetId, reason);
      }
      addNotification({ type: 'success', message: `Operation ${pastTense} successfully` });
      await refreshOperation();
      onOperationUpdated?.();
    } catch {
      addNotification({ type: 'error', message: `Failed to ${action} operation` });
    } finally {
      setActionLoading(null);
    }
  };

  const confirmStopAction = (action: 'cancel' | 'abort') => {
    if (!operation) return;

    const isCancel = action === 'cancel';
    const targetId = operation.id;
    confirmWithReason({
      title: isCancel ? 'Cancel Operation' : 'Abort Operation',
      message: isCancel
        ? `Cancel "${operation.command}" before it starts? It will not run.`
        : `Abort "${operation.command}" while it is running? Work already done is not rolled back.`,
      reasonPlaceholder: 'Why are you stopping this operation?',
      reasonHelpText: "Recorded on the operation's timeline for whoever looks at it next.",
      confirmLabel: isCancel ? 'Cancel Operation' : 'Abort Operation',
      // The dismiss button must not read as a second way to say "yes" on a
      // dialog whose subject is cancelling; the shared default is "Cancel".
      cancelLabel: isCancel ? 'Keep Operation' : 'Keep Running',
      variant: isCancel ? 'warning' : 'danger',
      onConfirm: (reason) => runStopAction(action, targetId, reason)
    });
  };

  if (!isOpen) return null;

  const formatDateTime = (dateString?: string) => {
    if (!dateString) return '—';
    return new Date(dateString).toLocaleString();
  };

  const formatDuration = () => {
    if (!operation?.started_at) return '—';
    const start = new Date(operation.started_at).getTime();
    const end = operation.completed_at
      ? new Date(operation.completed_at).getTime()
      : Date.now();
    const duration = Math.floor((end - start) / 1000);

    if (duration < 60) return `${duration} seconds`;
    if (duration < 3600) return `${Math.floor(duration / 60)}m ${duration % 60}s`;
    return `${Math.floor(duration / 3600)}h ${Math.floor((duration % 3600) / 60)}m`;
  };

  const tabs = [
    { id: 'info' as const, label: 'Information', icon: Activity },
    { id: 'events' as const, label: 'Events', icon: Clock },
    { id: 'options' as const, label: 'Options', icon: Server }
  ];

  const renderInfoTab = () => {
    if (!operation) return null;

    return (
      <div className="space-y-6">
        {/* Status and Progress */}
        <div className="bg-theme-background rounded-lg p-4 border border-theme">
          <div className="flex items-center justify-between mb-4">
            <h4 className="font-medium text-theme-primary">Status</h4>
            <Badge variant={statusColors[operation.status]}>
              {statusLabels[operation.status] || operation.status}
            </Badge>
          </div>

          {operation.status === 'running' && (
            <div className="space-y-2">
              <div className="flex items-center justify-between text-sm">
                <span className="text-theme-secondary">Progress</span>
                <span className="text-theme-primary font-medium">{operation.progress || 0}%</span>
              </div>
              <div className="w-full bg-theme-surface rounded-full h-3">
                <div
                  className="bg-theme-info-bg h-3 rounded-full transition-all duration-300"
                  style={{ width: `${operation.progress || 0}%` }}
                />
              </div>
            </div>
          )}
        </div>

        {/* Details Grid */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div className="space-y-4">
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Command</label>
              <p className="text-theme-primary font-medium">{operation.command}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Description</label>
              <p className="text-theme-primary">{operation.description || '—'}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Resource Type</label>
              {(() => {
                if (!operation.operable_type) {
                  return <p className="text-theme-primary">—</p>;
                }
                const t = resolveOperableType(operation.operable_type);
                if (t && operation.operable_id) {
                  return (
                    <EntityLink
                      type={t}
                      id={operation.operable_id}
                      label={operation.operable_type}
                    />
                  );
                }
                return <p className="text-theme-primary">{operation.operable_type}</p>;
              })()}
            </div>
          </div>
          <div className="space-y-4">
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Initiated By</label>
              <div className="flex items-center gap-2">
                <User className="w-4 h-4 text-theme-tertiary" />
                <span className="text-theme-primary">{operation.initiated_by_name || 'System'}</span>
              </div>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Duration</label>
              <p className="text-theme-primary">{formatDuration()}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Exclusive</label>
              <Badge variant={operation.exclusive ? 'warning' : 'secondary'}>
                {operation.exclusive ? 'Yes' : 'No'}
              </Badge>
            </div>
          </div>
        </div>

        {/* Timestamps */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 pt-4 border-t border-theme">
          <div>
            <div className="flex items-center gap-2 text-sm text-theme-secondary mb-1">
              <Calendar className="w-4 h-4" />
              <span>Scheduled</span>
            </div>
            <p className="text-theme-primary text-sm">{formatDateTime(operation.scheduled_at)}</p>
          </div>
          <div>
            <div className="flex items-center gap-2 text-sm text-theme-secondary mb-1">
              <Clock className="w-4 h-4" />
              <span>Started</span>
            </div>
            <p className="text-theme-primary text-sm">{formatDateTime(operation.started_at)}</p>
          </div>
          <div>
            <div className="flex items-center gap-2 text-sm text-theme-secondary mb-1">
              <CheckCircle className="w-4 h-4" />
              <span>Completed</span>
            </div>
            <p className="text-theme-primary text-sm">{formatDateTime(operation.completed_at)}</p>
          </div>
        </div>

        {/* Error Message */}
        {operation.error_message && (
          <div className="bg-theme-danger-bg border border-theme-danger-border/30 rounded-lg p-4">
            <div className="flex items-center gap-2 mb-2">
              <XCircle className="w-5 h-5 text-theme-error-fg" />
              <h4 className="font-medium text-theme-error-fg">Error</h4>
            </div>
            <pre className="text-sm text-theme-error-fg whitespace-pre-wrap font-mono">
              {operation.error_message}
            </pre>
          </div>
        )}
      </div>
    );
  };

  const renderEventsTab = () => {
    if (!operation) return null;

    const events = operation.events || [];

    if (events.length === 0) {
      return (
        <div className="text-center py-12">
          <Clock className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
          <p className="text-theme-secondary">No events recorded</p>
        </div>
      );
    }

    return (
      <div className="space-y-4">
        <h4 className="font-medium text-theme-primary">Event Timeline</h4>
        <div className="relative">
          <div className="absolute left-4 top-0 bottom-0 w-px bg-theme-background-secondary" />
          <div className="space-y-4">
            {events.map((event, idx: number) => {
              const eventType = String(event.type || 'info');
              const eventTimestamp = String(event.timestamp || '');
              const eventMessage = String(event.message || '');

              return (
                <div key={idx} className="relative flex items-start gap-4 pl-10">
                  <div className={`absolute left-2 w-4 h-4 rounded-full border-2 bg-theme-surface ${
                    eventType === 'error' ? 'border-theme-error-border' :
                    eventType === 'warning' ? 'border-theme-warning-border' :
                    eventType === 'success' ? 'border-theme-success-border' :
                    'border-theme-info-border'
                  }`} />
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <Badge
                        variant={
                          eventType === 'error' ? 'danger' :
                          eventType === 'warning' ? 'warning' :
                          eventType === 'success' ? 'success' :
                          'info'
                        }
                        size="xs"
                      >
                        {eventType}
                      </Badge>
                      <span className="text-xs text-theme-tertiary">
                        {eventTimestamp ? new Date(eventTimestamp).toLocaleTimeString() : '—'}
                      </span>
                    </div>
                    <p className="text-sm text-theme-primary">{eventMessage}</p>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    );
  };

  const renderOptionsTab = () => {
    if (!operation) return null;

    const options = operation.options || {};
    const hasOptions = Object.keys(options).length > 0;

    return (
      <div className="space-y-4">
        <h4 className="font-medium text-theme-primary">Operation Options</h4>
        {hasOptions ? (
          <pre className="bg-theme-background rounded-lg p-4 text-sm text-theme-primary overflow-x-auto border border-theme font-mono">
            {JSON.stringify(options, null, 2)}
          </pre>
        ) : (
          <div className="text-center py-12">
            <Server className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
            <p className="text-theme-secondary">No options configured</p>
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-3xl bg-theme-surface rounded-lg shadow-xl">
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Activity className="w-6 h-6 text-theme-info-fg" />
              <div>
                <h2 className="text-lg font-semibold text-theme-primary">
                  {loading ? 'Loading...' : operation?.command || 'Operation Details'}
                </h2>
                {operation && (
                  <p className="text-sm text-theme-secondary">
                    {operation.operable_type || 'System Operation'}
                  </p>
                )}
              </div>
            </div>
            <Button variant="ghost" size="sm" onClick={onClose}>
              <X className="w-5 h-5" />
            </Button>
          </div>

          {/* Tabs */}
          <div className="border-b border-theme">
            <nav className="flex -mb-px">
              {tabs.map(tab => (
                <button
                  key={tab.id}
                  onClick={() => setActiveTab(tab.id)}
                  className={`flex items-center gap-2 px-6 py-3 text-sm font-medium border-b-2 transition-colors ${
                    activeTab === tab.id
                      ? 'border-theme-info-border text-theme-info-fg'
                      : 'border-transparent text-theme-secondary hover:text-theme-primary hover:border-theme-tertiary'
                  }`}
                >
                  <tab.icon className="w-4 h-4" />
                  {tab.label}
                </button>
              ))}
            </nav>
          </div>

          {/* Content */}
          <div className="p-6 max-h-[60vh] overflow-y-auto">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : operation ? (
              <>
                {activeTab === 'info' && renderInfoTab()}
                {activeTab === 'events' && renderEventsTab()}
                {activeTab === 'options' && renderOptionsTab()}
              </>
            ) : (
              <div className="text-center py-12">
                <AlertCircle className="w-12 h-12 text-theme-error-fg mx-auto mb-4" />
                <p className="text-theme-error-fg mb-4">Failed to load operation details</p>
                {/* The same branch renders when there is no operationId at all,
                    where loadOperation is a no-op — do not offer a dead control. */}
                <Button variant="outline" size="sm" onClick={loadOperation} disabled={!operationId}>
                  <RefreshCw className="w-4 h-4 mr-2" />
                  Retry
                </Button>
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="flex items-center justify-between p-4 border-t border-theme">
            <div className="flex items-center gap-2">
              {/* Control buttons based on operation status */}
              {operation && canControlOperations && (
                <>
                  {/* Cancel for pending/scheduled operations */}
                  {(operation.status === 'pending' || operation.status === 'scheduled') && (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => confirmStopAction('cancel')}
                      disabled={actionLoading !== null}
                      className="text-theme-warning-fg border-theme-warning-border hover:bg-theme-warning-bg"
                    >
                      {actionLoading === 'cancel' ? (
                        <LoadingSpinner size="sm" className="mr-2" />
                      ) : (
                        <Ban className="w-4 h-4 mr-2" />
                      )}
                      Cancel
                    </Button>
                  )}

                  {/* Abort for running operations — `cancel` is illegal from
                      :running, so without this a wedged task has no recourse */}
                  {operation.status === 'running' && (
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => confirmStopAction('abort')}
                      disabled={actionLoading !== null}
                      className="text-theme-danger-fg border-theme-danger-border hover:bg-theme-danger-bg"
                    >
                      {actionLoading === 'abort' ? (
                        <LoadingSpinner size="sm" className="mr-2" />
                      ) : (
                        <StopCircle className="w-4 h-4 mr-2" />
                      )}
                      Abort
                    </Button>
                  )}
                </>
              )}
            </div>
            <Button variant="outline" onClick={onClose}>
              Close
            </Button>
          </div>
        </div>
      </div>

      {ConfirmationDialog}
    </div>
  );
};

export default OperationDetailModal;
