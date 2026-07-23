import React, { useCallback, useEffect, useState } from 'react';
import { Wrench, Plus, Trash2, Power, PowerOff } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { puppetApi } from '@system/features/system/services/api/puppetApi';
import type { PuppetAssignment } from '@system/features/system/services/api/puppetApi';
import type { SystemPuppetModule } from '@system/features/system/types/system.types';

// Puppet assignments for one node module (IMP-5dba18916d37) — operators
// attach puppet modules to a node module, toggle them, and remove them.
// Direction is by-node-module only: the backend nests everything under
// node_modules/:node_module_id.

interface ModulePuppetAssignmentsPanelProps {
  moduleId: string;
}

export const ModulePuppetAssignmentsPanel: React.FC<ModulePuppetAssignmentsPanelProps> = ({
  moduleId,
}) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.puppet.create');
  const canUpdate = hasPermission('system.puppet.update');
  const canDelete = hasPermission('system.puppet.delete');

  const [assignments, setAssignments] = useState<PuppetAssignment[]>([]);
  const [loading, setLoading] = useState(true);
  const [showAddForm, setShowAddForm] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      setAssignments(await puppetApi.getPuppetModuleAssignments(moduleId));
    } catch {
      addNotification({ type: 'error', message: 'Failed to load puppet assignments' });
    } finally {
      setLoading(false);
    }
  }, [moduleId, addNotification]);

  useEffect(() => { void refresh(); }, [refresh]);

  const handleToggle = useCallback(async (assignment: PuppetAssignment) => {
    setBusyId(assignment.id);
    try {
      await puppetApi.updatePuppetAssignment(moduleId, assignment.id, {
        enabled: !assignment.enabled,
      });
      void refresh();
      addNotification({
        type: 'success',
        message: `${assignment.puppet_module_name ?? 'Puppet module'} ${assignment.enabled ? 'disabled' : 'enabled'}`,
      });
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Update failed' });
    } finally {
      setBusyId(null);
    }
  }, [moduleId, addNotification, refresh]);

  const handleRemove = useCallback(async (assignment: PuppetAssignment) => {
    if (!window.confirm(
      `Remove puppet module "${assignment.puppet_module_name ?? assignment.puppet_module_id}" from this module?`
    )) return;
    setBusyId(assignment.id);
    try {
      await puppetApi.deletePuppetAssignment(moduleId, assignment.id);
      void refresh();
      addNotification({ type: 'success', message: 'Puppet assignment removed' });
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Remove failed' });
    } finally {
      setBusyId(null);
    }
  }, [moduleId, addNotification, refresh]);

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <Wrench size={16} className="text-theme-info-fg" />
          <h4 className="font-medium text-theme-primary">Puppet assignments</h4>
          {assignments.length > 0 && (
            <Badge variant="info" size="xs">{assignments.length}</Badge>
          )}
        </div>
        {canCreate && (
          <Button size="sm" variant="outline" onClick={() => setShowAddForm(true)}>
            <Plus size={14} className="mr-1" />
            Assign puppet module
          </Button>
        )}
      </div>
      <p className="text-xs text-theme-secondary">
        Puppet modules attached here are applied on nodes running this module,
        in ascending priority order (lowest number applies first).
      </p>

      {loading ? (
        <p className="text-sm text-theme-tertiary">Loading…</p>
      ) : assignments.length === 0 ? (
        <p className="text-sm text-theme-secondary">
          No puppet modules assigned to this module.
        </p>
      ) : (
        <ul className="divide-y divide-theme border border-theme rounded-lg">
          {assignments.map((assignment) => {
            const busy = busyId === assignment.id;
            return (
              <li key={assignment.id} className="px-3 py-2.5 flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <div className="flex items-center gap-2 text-sm">
                    <span className="font-medium text-theme-primary">
                      {assignment.puppet_module_name ?? assignment.puppet_module_id}
                    </span>
                    <Badge variant={assignment.enabled ? 'success' : 'secondary'} size="xs">
                      {assignment.enabled ? 'enabled' : 'disabled'}
                    </Badge>
                  </div>
                  <div className="mt-0.5 text-xs text-theme-tertiary">
                    Priority {assignment.priority ?? 0}
                  </div>
                </div>
                <div className="flex items-center gap-1">
                  {canUpdate && (
                    <Button
                      size="sm"
                      variant={assignment.enabled ? 'ghost' : 'outline'}
                      disabled={busy}
                      onClick={() => handleToggle(assignment)}
                      title={assignment.enabled ? 'Disable assignment' : 'Enable assignment'}
                    >
                      {assignment.enabled
                        ? <PowerOff size={14} className="text-theme-danger-fg" />
                        : <Power size={14} />}
                    </Button>
                  )}
                  {canDelete && (
                    <Button
                      size="sm"
                      variant="ghost"
                      disabled={busy}
                      onClick={() => handleRemove(assignment)}
                      title="Remove assignment"
                    >
                      <Trash2 size={14} className="text-theme-danger-fg" />
                    </Button>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}

      {showAddForm && (
        <AddPuppetAssignmentForm
          moduleId={moduleId}
          existingPuppetModuleIds={assignments.map((a) => a.puppet_module_id)}
          onClose={() => setShowAddForm(false)}
          onCreated={() => {
            setShowAddForm(false);
            void refresh();
          }}
        />
      )}
    </div>
  );
};

const AddPuppetAssignmentForm: React.FC<{
  moduleId: string;
  existingPuppetModuleIds: string[];
  onClose: () => void;
  onCreated: () => void;
}> = ({ moduleId, existingPuppetModuleIds, onClose, onCreated }) => {
  const { addNotification } = useNotifications();
  const [puppetModules, setPuppetModules] = useState<SystemPuppetModule[]>([]);
  const [puppetModuleId, setPuppetModuleId] = useState('');
  const [priority, setPriority] = useState(0);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    puppetApi.getPuppetModules({ per_page: 100 })
      .then(({ puppetModules: modules }) => {
        const available = modules.filter((m) => !existingPuppetModuleIds.includes(m.id));
        setPuppetModules(available);
        setPuppetModuleId((current) => current || (available[0]?.id ?? ''));
      })
      .catch(() => {
        addNotification({ type: 'error', message: 'Failed to load puppet modules' });
      });
    // existingPuppetModuleIds is derived from the parent's assignment list,
    // which is stable while this dialog is open.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addNotification]);

  const handleSubmit = async () => {
    if (!puppetModuleId) return;
    setSubmitting(true);
    try {
      await puppetApi.createPuppetAssignment(moduleId, {
        puppet_module_id: puppetModuleId,
        priority,
      });
      addNotification({ type: 'success', message: 'Puppet module assigned' });
      onCreated();
    } catch (e) {
      addNotification({ type: 'error', message: e instanceof Error ? e.message : 'Assign failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-black/50 flex items-center justify-center p-4">
      <div className="bg-theme-surface rounded-lg shadow-xl w-full max-w-md p-6">
        <h3 className="text-lg font-semibold mb-3 text-theme-primary">Assign puppet module</h3>

        {puppetModules.length === 0 ? (
          <p className="text-sm text-theme-secondary mb-4">
            No unassigned puppet modules available.
          </p>
        ) : (
          <>
            <label className="block text-sm text-theme-secondary mb-1" htmlFor="mpa-puppet-module">Puppet module</label>
            <select
              id="mpa-puppet-module"
              value={puppetModuleId}
              onChange={(e) => setPuppetModuleId(e.target.value)}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
            >
              {puppetModules.map((m) => (
                <option key={m.id} value={m.id}>{m.name}</option>
              ))}
            </select>

            <label className="block text-sm text-theme-secondary mb-1" htmlFor="mpa-priority">Priority</label>
            <input
              id="mpa-priority"
              type="number"
              value={priority}
              onChange={(e) => setPriority(Number(e.target.value) || 0)}
              className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-surface text-theme-primary mb-4"
            />
          </>
        )}

        <div className="flex justify-end gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            onClick={handleSubmit}
            disabled={!puppetModuleId || submitting || puppetModules.length === 0}
          >
            {submitting ? 'Assigning…' : 'Assign'}
          </Button>
        </div>
      </div>
    </div>
  );
};
