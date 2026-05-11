import React, { useState } from 'react';
import { Save, RotateCcw } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

interface Props {
  module: SystemNodeModule & {
    consent_budget_per_day?: number | null;
    consent_budget_used_count?: number;
    consent_budget_window_start_at?: string | null;
  };
  onUpdated?: (module: SystemNodeModule) => void;
}

// Operator-facing editor for module consent budget (Golden Eclipse Block R).
// Lets the operator set a daily ceiling on autonomous decisions affecting
// this module. When budget is exhausted, FleetAutonomyService.gate_action!
// forces require_approval until the next 24-hour window resets.
//
// "Reset window" button manually clears the used count without changing
// the budget — useful when the operator approved a flurry of legitimate
// decisions and wants to restore the budget without waiting 24 hours.
export const ConsentBudgetEditor: React.FC<Props> = ({ module, onUpdated }) => {
  const { addNotification } = useNotifications();
  const [budget, setBudget] = useState<string>(
    module.consent_budget_per_day != null ? String(module.consent_budget_per_day) : ''
  );
  const [saving, setSaving] = useState(false);

  const used = module.consent_budget_used_count ?? 0;
  const max = module.consent_budget_per_day ?? null;
  const remaining = max != null ? Math.max(0, max - used) : null;
  const windowStart = module.consent_budget_window_start_at;

  const handleSave = async (): Promise<void> => {
    setSaving(true);
    try {
      const value = budget === '' ? null : Math.max(0, parseInt(budget, 10) || 0);
      const updated = await systemApi.updateModule(module.id, { consent_budget_per_day: value });
      addNotification({ type: 'success', message: 'Consent budget updated' });
      onUpdated?.(updated);
    } catch (err) {
      addNotification({ type: 'error', message: 'Update failed' });
    } finally {
      setSaving(false);
    }
  };

  const handleReset = async (): Promise<void> => {
    setSaving(true);
    try {
      const updated = await systemApi.updateModule(module.id, {
        consent_budget_used_count: 0,
        consent_budget_window_start_at: new Date().toISOString()
      });
      addNotification({ type: 'success', message: 'Window reset' });
      onUpdated?.(updated);
    } catch {
      addNotification({ type: 'error', message: 'Reset failed' });
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="bg-theme-surface border border-theme rounded-lg p-4">
      <h3 className="text-sm font-semibold mb-2">Consent Budget</h3>
      <p className="text-xs text-theme-tertiary mb-3">
        Daily ceiling on autonomous decisions for this module. When exhausted, every
        subsequent decision is forced through require_approval until the 24-hour
        window resets.
      </p>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-3 mb-3">
        <div>
          <label className="block text-xs text-theme-tertiary mb-1">Per-day budget</label>
          <input
            type="number"
            min="0"
            value={budget}
            onChange={(e) => setBudget(e.target.value)}
            className="w-full px-2 py-1.5 text-sm rounded border border-theme bg-theme-background"
            placeholder="unlimited"
          />
        </div>
        <div>
          <div className="block text-xs text-theme-tertiary mb-1">Used (current window)</div>
          <div className="text-base font-mono">{used}{max ? `/${max}` : ''}</div>
        </div>
        <div>
          <div className="block text-xs text-theme-tertiary mb-1">Remaining</div>
          <div className={`text-base font-mono ${remaining === 0 ? 'text-theme-error' : ''}`}>
            {remaining ?? '∞'}
          </div>
        </div>
      </div>

      {windowStart && (
        <div className="text-xs text-theme-tertiary mb-3">
          Window started: {new Date(windowStart).toLocaleString()}
        </div>
      )}

      <div className="flex gap-2">
        <Button size="sm" variant="primary" onClick={handleSave} disabled={saving}>
          <Save size={12} /> Save
        </Button>
        <Button size="sm" variant="secondary" onClick={handleReset} disabled={saving || used === 0}>
          <RotateCcw size={12} /> Reset Window
        </Button>
      </div>
    </div>
  );
};

export default ConsentBudgetEditor;
