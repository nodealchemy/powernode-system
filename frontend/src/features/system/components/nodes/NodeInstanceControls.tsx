import React, { useState, useCallback } from 'react';
import { Play, Square, RotateCw, MoreVertical, Power, Search, XOctagon } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeInstance } from '@system/features/system/types/system.types';
import { AttributionResultModal } from '@system/features/system/components/fleet/AttributionResultModal';

type ControlAction = 'start' | 'stop' | 'reboot' | 'terminate';

interface NodeInstanceControlsProps {
  /** The instance to control */
  instance: SystemNodeInstance;
  /** Callback when an action completes */
  onActionComplete?: () => void;
  /** Show as compact dropdown menu */
  compact?: boolean;
  /** Additional CSS classes */
  className?: string;
}

/**
 * NodeInstanceControls - Control buttons for node instances
 *
 * Provides Start, Stop, and Reboot actions for node instances
 * with permission checks and loading states.
 */
export const NodeInstanceControls: React.FC<NodeInstanceControlsProps> = ({
  instance,
  onActionComplete,
  compact = false,
  className = ''
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const [loading, setLoading] = useState<string | null>(null);
  const [showMenu, setShowMenu] = useState(false);

  const canControl = hasPermission('system.instances.control');

  // Determine available actions based on instance status
  const isRunning = instance.status === 'running';
  const isStopped = instance.status === 'stopped';
  const isErrored = instance.status === 'error';
  const isTerminated = instance.status === 'terminated';
  const isPending = instance.status === 'pending' || instance.status === 'starting' || instance.status === 'stopping';
  // Terminate is allowed from running/stopped/error per backend `can_terminate?`
  const canTerminate = (isRunning || isStopped || isErrored) && !isTerminated;

  // Two-click confirm pattern for terminate to prevent accidental destruction.
  // First click sets a 5-second armed window; second click within that window fires.
  const [terminateArmed, setTerminateArmed] = useState(false);

  // Action handlers
  const handleAction = useCallback(async (action: ControlAction) => {
    if (!canControl) return;

    if (action === 'terminate' && !terminateArmed) {
      setTerminateArmed(true);
      setTimeout(() => setTerminateArmed(false), 5000);
      return;
    }

    setLoading(action);
    setShowMenu(false);
    setTerminateArmed(false);

    try {
      switch (action) {
        case 'start':
          await systemApi.startInstance(instance.node_id, instance.id);
          addNotification({
            type: 'success',
            message: `Starting instance ${instance.name}...`
          });
          break;
        case 'stop':
          await systemApi.stopInstance(instance.node_id, instance.id);
          addNotification({
            type: 'success',
            message: `Stopping instance ${instance.name}...`
          });
          break;
        case 'reboot':
          await systemApi.rebootInstance(instance.node_id, instance.id);
          addNotification({
            type: 'success',
            message: `Rebooting instance ${instance.name}...`
          });
          break;
        case 'terminate':
          await systemApi.terminateInstance(instance.node_id, instance.id);
          addNotification({
            type: 'success',
            message: `Terminating instance ${instance.name}...`
          });
          break;
      }
      onActionComplete?.();
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to ${action} instance: ${errorMessage}`
      });
    } finally {
      setLoading(null);
    }
  }, [canControl, instance.node_id, instance.id, instance.name, addNotification, onActionComplete, terminateArmed]);

  if (!canControl) {
    return null;
  }

  // Compact dropdown mode
  if (compact) {
    return (
      <div className={`relative ${className}`}>
        <Button
          variant="ghost"
          size="sm"
          onClick={() => setShowMenu(!showMenu)}
          disabled={isPending}
          className="p-1"
        >
          <MoreVertical className="w-4 h-4" />
        </Button>

        {showMenu && (
          <>
            {/* Backdrop to close menu */}
            <div
              className="fixed inset-0 z-10"
              onClick={() => setShowMenu(false)}
            />
            {/* Menu */}
            <div className="absolute right-0 top-full mt-1 z-20 bg-theme-surface border border-theme rounded-lg shadow-lg py-1 min-w-[120px]">
              {isStopped && (
                <button
                  onClick={() => handleAction('start')}
                  disabled={loading === 'start'}
                  className="w-full flex items-center gap-2 px-3 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover disabled:opacity-50"
                >
                  <Play className="w-4 h-4 text-theme-success" />
                  {loading === 'start' ? 'Starting...' : 'Start'}
                </button>
              )}
              {isRunning && (
                <>
                  <button
                    onClick={() => handleAction('stop')}
                    disabled={loading === 'stop'}
                    className="w-full flex items-center gap-2 px-3 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover disabled:opacity-50"
                  >
                    <Square className="w-4 h-4 text-theme-danger" />
                    {loading === 'stop' ? 'Stopping...' : 'Stop'}
                  </button>
                  <button
                    onClick={() => handleAction('reboot')}
                    disabled={loading === 'reboot'}
                    className="w-full flex items-center gap-2 px-3 py-2 text-sm text-theme-primary hover:bg-theme-surface-hover disabled:opacity-50"
                  >
                    <RotateCw className="w-4 h-4 text-theme-warning" />
                    {loading === 'reboot' ? 'Rebooting...' : 'Reboot'}
                  </button>
                </>
              )}
              {canTerminate && (
                <button
                  onClick={() => handleAction('terminate')}
                  disabled={loading === 'terminate'}
                  className={`w-full flex items-center gap-2 px-3 py-2 text-sm hover:bg-theme-surface-hover disabled:opacity-50 ${
                    terminateArmed ? 'text-theme-error font-medium' : 'text-theme-primary'
                  }`}
                >
                  <XOctagon className="w-4 h-4 text-theme-error" />
                  {loading === 'terminate'
                    ? 'Terminating...'
                    : terminateArmed
                    ? 'Click again to confirm'
                    : 'Terminate'}
                </button>
              )}
              {!isRunning && !isStopped && !isErrored && (
                <div className="px-3 py-2 text-sm text-theme-secondary">
                  Instance is {instance.status}
                </div>
              )}
            </div>
          </>
        )}
      </div>
    );
  }

  // Standard button mode
  return (
    <div className={`flex items-center gap-2 ${className}`}>
      {isStopped && (
        <Button
          variant="success"
          size="sm"
          onClick={() => handleAction('start')}
          disabled={loading !== null}
          className="flex items-center gap-1"
        >
          {loading === 'start' ? (
            <>
              <RotateCw className="w-4 h-4 animate-spin" />
              Starting...
            </>
          ) : (
            <>
              <Play className="w-4 h-4" />
              Start
            </>
          )}
        </Button>
      )}

      {isRunning && (
        <>
          <Button
            variant="danger"
            size="sm"
            onClick={() => handleAction('stop')}
            disabled={loading !== null}
            className="flex items-center gap-1"
          >
            {loading === 'stop' ? (
              <>
                <RotateCw className="w-4 h-4 animate-spin" />
                Stopping...
              </>
            ) : (
              <>
                <Square className="w-4 h-4" />
                Stop
              </>
            )}
          </Button>
          <Button
            variant="warning"
            size="sm"
            onClick={() => handleAction('reboot')}
            disabled={loading !== null}
            className="flex items-center gap-1"
          >
            {loading === 'reboot' ? (
              <>
                <RotateCw className="w-4 h-4 animate-spin" />
                Rebooting...
              </>
            ) : (
              <>
                <RotateCw className="w-4 h-4" />
                Reboot
              </>
            )}
          </Button>
        </>
      )}

      {canTerminate && (
        <Button
          variant={terminateArmed ? 'danger' : 'outline'}
          size="sm"
          onClick={() => handleAction('terminate')}
          disabled={loading !== null}
          className="flex items-center gap-1"
          title={terminateArmed ? 'Click again to confirm termination' : 'Terminate instance'}
        >
          {loading === 'terminate' ? (
            <>
              <RotateCw className="w-4 h-4 animate-spin" />
              Terminating...
            </>
          ) : (
            <>
              <XOctagon className="w-4 h-4" />
              {terminateArmed ? 'Confirm?' : 'Terminate'}
            </>
          )}
        </Button>
      )}

      {isPending && (
        <div className="flex items-center gap-2 text-sm text-theme-secondary">
          <Power className="w-4 h-4 animate-pulse" />
          <span className="capitalize">{instance.status}...</span>
        </div>
      )}

      {/* Attribute Failure entry — opens AttributionResultModal */}
      {(instance.status === 'error' || instance.status === 'stopped' || instance.status === 'running') && (
        <AttributeFailureLauncher instanceId={instance.id} />
      )}
    </div>
  );
};

// Tiny launcher component so the modal state is local to the button row
// rather than polluting NodeInstanceControls' top-level state.
const AttributeFailureLauncher: React.FC<{ instanceId: string }> = ({ instanceId }) => {
  const [open, setOpen] = useState(false);
  const { hasPermission } = usePermissions();
  if (!hasPermission('system.node_instances.read')) return null;
  return (
    <>
      <Button
        variant="outline"
        size="sm"
        onClick={() => setOpen(true)}
        className="flex items-center gap-1"
        title="Rank recent module changes by likelihood of causing this instance's failure"
      >
        <Search className="w-4 h-4" />
        Attribute Failure
      </Button>
      <AttributionResultModal
        instanceId={instanceId}
        isOpen={open}
        onClose={() => setOpen(false)}
      />
    </>
  );
};

export default NodeInstanceControls;
