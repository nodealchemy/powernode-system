import React, { useCallback, useRef, useState } from 'react';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
import type { ConfirmationVariant } from '@/shared/components/ui/ConfirmationModal';
import { FormField } from '@/shared/components/ui/FormField';

/**
 * The body of a reason-carrying confirmation: the caller's sentence plus an
 * optional free-text reason forwarded to the action's API client.
 *
 * It owns its own state and reports upward through `onReasonChange` on purpose.
 * `useConfirmation` snapshots the `message` element when `confirm()` is called
 * and re-renders that same element for the life of the dialog, so a *controlled*
 * field driven by the caller's state would never show what was typed — the
 * snapshot still holds the props from the render that created it. Keeping the
 * value here and pushing it into a ref is what makes the field work at all.
 */
const ReasonPrompt: React.FC<{
  prompt: React.ReactNode;
  placeholder?: string;
  helpText?: string;
  required?: boolean;
  onReasonChange: (reason: string) => void;
}> = ({ prompt, placeholder, helpText, required, onReasonChange }) => {
  const [reason, setReason] = useState('');

  return (
    <div className="space-y-4">
      {typeof prompt === 'string' ? <p>{prompt}</p> : prompt}
      <FormField
        label={required ? 'Reason (required)' : 'Reason (optional)'}
        type="textarea"
        rows={2}
        size="sm"
        required={required}
        value={reason}
        onChange={(value) => {
          setReason(value);
          onReasonChange(value);
        }}
        placeholder={placeholder}
        helpText={helpText}
      />
    </div>
  );
};

export interface ReasonConfirmOptions {
  title: string;
  message: React.ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  variant?: ConfirmationVariant;
  /** Placeholder for the reason field. */
  reasonPlaceholder?: string;
  /** Help text under the reason field. */
  reasonHelpText?: string;
  /**
   * Require a non-blank reason: the confirm button stays disabled until one is
   * typed. For an action whose audit trail is the only record of WHY it was
   * taken — a destructive, never-auto-run operator step — an optional reason is
   * an unlabelled hole in that trail.
   */
  reasonRequired?: boolean;
  /**
   * Runs only if the operator confirms. Receives the trimmed reason, or
   * `undefined` when none was typed — every caller forwards it straight to an
   * API client whose `reason` parameter is optional, and `''` is not the same
   * as "not supplied".
   */
  onConfirm: (reason?: string) => void | Promise<void>;
}

/**
 * In-app replacement for the `window.prompt(message, '')` pattern that operator
 * panels used to capture an optional reason before a destructive action
 * (IMP-e5cba23c32fd).
 *
 * `window.prompt` is a blocking browser dialog: it is unthemed, unstyleable,
 * silently suppressed in sandboxed iframes and by browsers that block repeated
 * dialogs, and it renders the caller's `\n`-formatted warning as flat
 * unformatted text. This wraps the shared ConfirmationModal instead, so the
 * warning gets the danger styling it was written for and the reason gets a real
 * field.
 *
 * The shape deliberately mirrors `useConfirmation`: `confirmWithReason` takes an
 * `onConfirm` callback rather than returning a promise, because the underlying
 * hook has no cancel notification to resolve one with. Cancelling simply never
 * runs the callback, which is what `prompt` returning `null` meant.
 *
 *   const { confirmWithReason, ConfirmationDialog } = useReasonConfirm();
 *   …
 *   confirmWithReason({ title, message, variant: 'danger', onConfirm: async (reason) => … });
 *   …
 *   {ConfirmationDialog}
 */
export function useReasonConfirm() {
  const { confirm, close, ConfirmationDialog } = useConfirmation();
  // Written by ReasonPrompt while the dialog is open; read once on confirm. A
  // ref (not state) because the dialog body is a snapshotted element — see
  // ReasonPrompt.
  const reasonRef = useRef('');
  // State MIRROR of the same value, written on every keystroke purely to force
  // a re-render of the owning component. `useConfirmation` builds its
  // ConfirmationDialog fresh on each of those renders, which is what
  // re-evaluates the `confirmDisabled` predicate below; the ref alone changes
  // nothing on screen. The FIELD still reads from ReasonPrompt's own state —
  // driving it from here would break it, for the reason ReasonPrompt documents.
  const [, setReasonMirror] = useState('');
  // Core's `confirm` is a plain function rebuilt every render, so depending on
  // it directly would make `confirmWithReason` a new value every render too —
  // an inert useCallback here, and an inert one in any caller that lists
  // confirmWithReason in its own deps. Going through a ref makes the identity
  // genuinely stable, so a caller CAN depend on it.
  const confirmRef = useRef(confirm);
  confirmRef.current = confirm;

  const confirmWithReason = useCallback(
    ({
      title,
      message,
      confirmLabel,
      cancelLabel,
      variant = 'danger',
      reasonPlaceholder,
      reasonHelpText,
      reasonRequired = false,
      onConfirm,
    }: ReasonConfirmOptions) => {
      // Reset first: the ref outlives any single dialog, so without this a
      // reason typed into a cancelled confirmation would be sent by the next one.
      reasonRef.current = '';
      setReasonMirror('');
      confirmRef.current({
        title,
        message: (
          <ReasonPrompt
            prompt={message}
            placeholder={reasonPlaceholder}
            helpText={reasonHelpText}
            required={reasonRequired}
            onReasonChange={(reason) => {
              reasonRef.current = reason;
              setReasonMirror(reason);
            }}
          />
        ),
        confirmLabel,
        cancelLabel,
        variant,
        confirmDisabled: reasonRequired
          ? () => reasonRef.current.trim() === ''
          : undefined,
        onConfirm: () => onConfirm(reasonRef.current.trim() || undefined),
      });
    },
    [],
  );

  return { confirmWithReason, close, ConfirmationDialog };
}
