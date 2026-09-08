import React from 'react';
import { AlertTriangle } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import type { TemplateCompositionReportEntry } from '@system/features/system/services/api/templatesApi';

interface CompositionReportPanelProps {
  entries: TemplateCompositionReportEntry[];
  /** Sentence above the list, naming which write produced the report. */
  intro: string;
}

/**
 * Renders the `composition_report` that clone and import RETURN but do not
 * enforce.
 *
 * The severity is rendered per entry rather than for the panel as a whole,
 * because that is the whole reason the backend renamed this away from
 * `warnings`: one payload can carry a blocking verdict the operator must act
 * on next to an advisory one they may ignore, and a single panel-level heading
 * would flatten the distinction back out. Shared by both modals so the two
 * surfaces cannot drift apart on how a verdict reads.
 */
export const CompositionReportPanel: React.FC<CompositionReportPanelProps> = ({ entries, intro }) => {
  if (entries.length === 0) return null;

  const blocking = entries.filter((e) => e.severity === 'error').length;

  return (
    <div className="bg-theme-warning-bg border border-theme-warning-border rounded-lg p-4">
      <div className="flex items-center gap-2 mb-2">
        <AlertTriangle className="w-5 h-5 text-theme-warning-fg" />
        <h4 className="font-medium text-theme-warning-fg">
          Composition report ({entries.length})
        </h4>
      </div>
      <p className="text-sm text-theme-secondary mb-3">
        {intro}
        {blocking > 0 && (
          <>
            {' '}
            {blocking} of these {blocking === 1 ? 'is' : 'are'} an error-severity conflict that
            later assignments will now treat as acceptable baseline.
          </>
        )}
      </p>
      <ul className="space-y-2">
        {entries.map((entry, idx) => (
          <li key={idx} className="flex items-start gap-2 text-sm">
            <Badge variant={entry.severity === 'error' ? 'danger' : 'warning'} size="xs">
              {entry.severity}
            </Badge>
            <span className="text-theme-primary">
              <span className="font-mono text-xs text-theme-secondary">{entry.kind}</span>
              {entry.detail ? ` — ${entry.detail}` : ''}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
};

export default CompositionReportPanel;
