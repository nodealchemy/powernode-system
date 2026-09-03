import React, { useCallback, useEffect, useState } from 'react';
import { History, Undo2 } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { modulesApi } from '@system/features/system/services/api/modulesApi';
import type {
  SystemNodeModuleVersion,
  SystemModulePromotionState,
} from '@system/features/system/types/system.types';

// Version-lifecycle panel for the module detail modal (IMP-c4235dad3779).
// Lists NodeModuleVersions, marks the module's current version, and exposes
// the operator transitions: promote (built → staging → blessed → live →
// retired) and spec rollback to a prior version.

// Client-side mirror of System::NodeModuleVersion::PROMOTION_TRANSITIONS —
// used only to decide which buttons to render; the backend re-validates
// every transition and 422s on anything illegal.
const PROMOTION_TRANSITIONS: Record<SystemModulePromotionState, SystemModulePromotionState[]> = {
  built: ['staging', 'retired'],
  staging: ['blessed', 'retired', 'built'],
  blessed: ['live', 'retired'],
  live: ['retired'],
  retired: [],
};

const STATE_BADGE_VARIANT: Record<SystemModulePromotionState, 'success' | 'info' | 'warning' | 'secondary'> = {
  built: 'secondary',
  staging: 'warning',
  blessed: 'info',
  live: 'success',
  retired: 'secondary',
};

interface ModuleVersionsPanelProps {
  moduleId: string;
  /** system.modules.update — gates promote + rollback controls. */
  canUpdate: boolean;
  /** Called after a rollback changes the module (spec + current version). */
  onModuleChanged?: () => void;
}

export const ModuleVersionsPanel: React.FC<ModuleVersionsPanelProps> = ({
  moduleId,
  canUpdate,
  onModuleChanged,
}) => {
  const { addNotification } = useNotifications();
  const [versions, setVersions] = useState<SystemNodeModuleVersion[]>([]);
  const [currentVersionId, setCurrentVersionId] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busyVersionId, setBusyVersionId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const result = await modulesApi.getModuleVersions(moduleId);
      setVersions(result.versions);
      setCurrentVersionId(result.current_version_id);
    } catch {
      addNotification({ type: 'error', message: 'Failed to load module versions' });
    } finally {
      setLoading(false);
    }
  }, [moduleId, addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  const handlePromote = useCallback(async (
    version: SystemNodeModuleVersion,
    targetState: SystemModulePromotionState
  ) => {
    setBusyVersionId(version.id);
    try {
      const result = await modulesApi.promoteModuleVersion(version.id, targetState);
      addNotification({
        type: 'success',
        message: `v${version.version_number} promoted to ${targetState}`,
      });
      // Consult-and-WARN (operator ruling D17): the backend never refuses a
      // manual promote, but it evaluates PromotionCriteria for a gated target
      // and says so when the fleet has not earned the rung. Surface that
      // beside the success — the only other record is a FleetEvent
      // (`system.module_promotion_criteria_override`) the operator would
      // otherwise have to know to go looking for.
      if (result.promotion_criteria_warning) {
        addNotification({
          type: 'warning',
          message: `v${version.version_number} ${result.promotion_criteria_warning}`,
        });
      }
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Promotion failed' });
    } finally {
      setBusyVersionId(null);
    }
  }, [addNotification, refresh]);

  const handleRollback = useCallback(async (version: SystemNodeModuleVersion) => {
    if (!window.confirm(
      `Roll the module spec back to v${version.version_number}? ` +
      'This snapshots a new version from the prior state and repoints the module at it.'
    )) return;
    setBusyVersionId(version.id);
    try {
      const result = await modulesApi.rollbackModule(moduleId, { targetVersionId: version.id });
      addNotification({
        type: 'success',
        message: `Rolled back to v${version.version_number} (new v${result.new_version.version_number})`,
      });
      onModuleChanged?.();
      void refresh();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Rollback failed' });
    } finally {
      setBusyVersionId(null);
    }
  }, [moduleId, addNotification, onModuleChanged, refresh]);

  return (
    <div className="space-y-3">
      <div className="flex items-center gap-2">
        <History size={16} className="text-theme-info-fg" />
        <h4 className="font-medium text-theme-primary">Version history</h4>
      </div>
      <p className="text-xs text-theme-secondary">
        Promotion lifecycle: built → staging → blessed → live → retired. The
        backend validates every transition; rollback snapshots the prior spec
        as a new version and repoints the module at it. Promoting to blessed
        consults the promotion criteria (instances running the version, dwell)
        and warns — it never refuses — when the fleet has not yet earned it.
      </p>

      {loading ? (
        <p className="text-sm text-theme-tertiary">Loading…</p>
      ) : versions.length === 0 ? (
        <p className="text-sm text-theme-secondary">
          No versions yet. Versions appear after the module&apos;s first publish.
        </p>
      ) : (
        <ul className="divide-y divide-theme border border-theme rounded-lg">
          {versions.map((version) => {
            const isCurrent = version.id === currentVersionId;
            const busy = busyVersionId === version.id;
            const targets = canUpdate ? PROMOTION_TRANSITIONS[version.promotion_state] ?? [] : [];
            return (
              <li key={version.id} className="px-3 py-2.5">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 text-sm">
                      <span className="font-medium text-theme-primary">v{version.version_number}</span>
                      <Badge variant={STATE_BADGE_VARIANT[version.promotion_state] ?? 'secondary'} size="xs">
                        {version.promotion_state}
                      </Badge>
                      {isCurrent && (
                        <Badge variant="primary" size="xs">current</Badge>
                      )}
                    </div>
                    <div className="mt-1 text-xs text-theme-tertiary">
                      {new Date(version.created_at).toLocaleString()}
                      {version.oci_digest && (
                        <span className="font-mono ml-2" title={version.oci_digest}>
                          {version.oci_digest.slice(0, 19)}…
                        </span>
                      )}
                    </div>
                    {version.changelog && (
                      <p className="mt-1 text-xs text-theme-secondary">{version.changelog}</p>
                    )}
                  </div>
                  <div className="flex items-center gap-1 flex-wrap justify-end">
                    {targets.map((target) => (
                      <Button
                        key={target}
                        size="sm"
                        variant="outline"
                        disabled={busy}
                        onClick={() => handlePromote(version, target)}
                        title={`Promote to ${target}`}
                      >
                        → {target}
                      </Button>
                    ))}
                    {canUpdate && !isCurrent && (
                      <Button
                        size="sm"
                        variant="ghost"
                        disabled={busy}
                        onClick={() => handleRollback(version)}
                        title="Roll back to this version"
                      >
                        <Undo2 size={14} />
                      </Button>
                    )}
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
};
