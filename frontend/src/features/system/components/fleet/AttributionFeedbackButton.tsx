import React, { useState } from 'react';
import { CheckCircle2, XCircle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { apiClient } from '@/shared/services/apiClient';

interface Props {
  instanceId: string;
  candidateModuleId: string;
  candidateKind: string;
  onSubmitted?: () => void;
}

// Operator confirm/reject of an attribute_failure candidate. Posts to
// /system/fleet/attribution_feedback which records a CompoundLearning
// the next AttributeFailureExecutor invocation reads back to weight
// confirmed (1.5x) or rejected (0.7x) candidate scores.
//
// Reference: Golden Eclipse plan Block Q — attribution feedback loop.
export const AttributionFeedbackButton: React.FC<Props> = ({
  instanceId,
  candidateModuleId,
  candidateKind,
  onSubmitted
}) => {
  const { showNotification } = useNotifications();
  const [note, setNote] = useState('');
  const [showNote, setShowNote] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  const submit = async (confirmed: boolean): Promise<void> => {
    setSubmitting(true);
    try {
      await apiClient.post('/system/fleet/attribution_feedback', {
        instance_id: instanceId,
        candidate_module_id: candidateModuleId,
        candidate_kind: candidateKind,
        confirmed,
        note: note.trim() || undefined
      });
      showNotification({
        type: 'success',
        message: confirmed
          ? 'Confirmed — future calls will boost similar candidates'
          : 'Rejected — future calls will downweight similar candidates'
      });
      setNote('');
      setShowNote(false);
      onSubmitted?.();
    } catch {
      showNotification({ type: 'error', message: 'Feedback submission failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="space-y-2">
      <div className="flex gap-2">
        <Button size="xs" variant="secondary" onClick={() => submit(true)} disabled={submitting}>
          <CheckCircle2 size={12} className="text-theme-success" /> Confirm
        </Button>
        <Button size="xs" variant="ghost" onClick={() => submit(false)} disabled={submitting}>
          <XCircle size={12} className="text-theme-error" /> Reject
        </Button>
        {!showNote && (
          <Button size="xs" variant="ghost" onClick={() => setShowNote(true)}>
            Add note
          </Button>
        )}
      </div>
      {showNote && (
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          rows={2}
          placeholder="Optional context for the learning record…"
          className="w-full px-2 py-1 text-xs rounded border border-theme-border bg-theme-background"
        />
      )}
    </div>
  );
};

export default AttributionFeedbackButton;
