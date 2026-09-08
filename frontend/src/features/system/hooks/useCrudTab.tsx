import React, { useCallback, useEffect, useState } from 'react';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';

/**
 * The shared body of the catalog/* and compute/* CRUD tabs (IMP-9fa34731baeb).
 *
 * Nine tabs carried the same 72–131 lines with only the nouns changed: the
 * same form-modal + edit-entity + refreshKey state, the same onActionsReady
 * publish/unpublish effect, and the same confirm-then-delete-then-refresh
 * flow down to the error-string template. A fix to the delete flow had to be
 * applied nine times, and each application was a chance to miss one.
 *
 * NOT every tab in those directories belongs here. NodesTab keeps its own
 * delete confirmation: it loads the node first so the dialog can name it and
 * warn that N attached instances will be destroyed with it, which a generic
 * message cannot express. A hook that swallowed that case would have to drop
 * the warning, so NodesTab is deliberately left alone.
 *
 * WHY THE LABELS ARE FOUR SEPARATE OPTIONS rather than derived from one noun:
 * the operator-visible strings do not share a casing rule. Puppet modules
 * title "Delete Puppet Module", confirm with "Delete Module", and report
 * "Puppet module deleted successfully" — and each of those exact sentences is
 * asserted by a tab spec. Deriving them would silently rewrite the UI.
 */
export interface UseCrudTabOptions {
  /** Title-case noun for the dialog title: `Delete ${entityLabel}`. */
  entityLabel: string;
  /** The delete call. Rejecting must leave the list unrefreshed. */
  deleteFn: (id: string) => Promise<unknown>;
  /** Body of the delete confirmation — the consequences, in the tab's words. */
  deleteMessage: string;
  /** Page-owned action handle. Published on mount, nulled on unmount. */
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
  /** Defaults to `Delete ${entityLabel}`. */
  confirmLabel?: string;
  /** Subject of `${successLabel} deleted successfully`. Defaults to entityLabel. */
  successLabel?: string;
  /** Object of `Failed to delete ${errorLabel}`. Defaults to the lower-cased entityLabel. */
  errorLabel?: string;
}

export interface UseCrudTabResult<T> {
  showFormModal: boolean;
  editEntity: T | null;
  refreshKey: number;
  /** Open the form for a NEW entity — clears any entity under edit. */
  handleCreate: () => void;
  /** Open the form holding an existing entity. */
  handleEdit: (entity: T) => void;
  /** Confirm, then delete, then refresh. Never refreshes on failure. */
  handleDeleteClick: (id: string) => void;
  /** The form saved: refresh the list and drop the entity. */
  handleSaved: () => void;
  /** Close the form and drop the entity. */
  closeForm: () => void;
  /** Bump refreshKey from a flow the hook does not own (attach, clone, …). */
  triggerRefresh: () => void;
  /**
   * The underlying confirm, for a tab's OWN destructive action that is not a
   * delete — VolumesTab's detach, say. Exposed so such an action reuses this
   * hook's single ConfirmationDialog instead of the tab mounting a second one.
   */
  confirm: ReturnType<typeof useConfirmation>['confirm'];
  ConfirmationDialog: React.ReactNode;
}

export function useCrudTab<T>({
  entityLabel,
  deleteFn,
  deleteMessage,
  onActionsReady,
  confirmLabel,
  successLabel,
  errorLabel,
}: UseCrudTabOptions): UseCrudTabResult<T> {
  const { addNotification } = useNotifications();
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [editEntity, setEditEntity] = useState<T | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const triggerRefresh = useCallback(() => setRefreshKey((k) => k + 1), []);

  // Clearing the entity is the load-bearing half: without it, "New" opens the
  // form still holding the last-edited row and the operator edits an existing
  // entity believing they created one.
  const handleCreate = useCallback(() => {
    setEditEntity(null);
    setShowFormModal(true);
  }, []);

  const handleEdit = useCallback((entity: T) => {
    setEditEntity(entity);
    setShowFormModal(true);
  }, []);

  const closeForm = useCallback(() => {
    setShowFormModal(false);
    setEditEntity(null);
  }, []);

  const handleSaved = useCallback(() => {
    setRefreshKey((k) => k + 1);
    setEditEntity(null);
  }, []);

  // handleCreate is a stable useCallback, so this effect runs on mount and
  // unmount only. An unstable identity here would republish the handle on
  // every render, re-entering the parent's setState.
  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate]);

  // Not memo-stable in practice: `confirm` is rebuilt by useConfirmation on
  // every render, so this callback is too. That is fine and is what the tabs
  // did before — it is only ever passed as an `onDelete` prop, never sits in a
  // dependency array, and is never used as a key. The deps are listed in full
  // so a future caller passing changing labels still gets them.
  const handleDeleteClick = useCallback(
    (id: string) => {
      confirm({
        title: `Delete ${entityLabel}`,
        message: deleteMessage,
        confirmLabel: confirmLabel ?? `Delete ${entityLabel}`,
        variant: 'danger',
        onConfirm: async () => {
          try {
            await deleteFn(id);
            addNotification({
              type: 'success',
              message: `${successLabel ?? entityLabel} deleted successfully`,
            });
            // Only on success: a list that reloads after a failed destructive
            // action reads to the operator as though it worked.
            setRefreshKey((k) => k + 1);
          } catch (error) {
            addNotification({
              type: 'error',
              message: `Failed to delete ${errorLabel ?? entityLabel.toLowerCase()}: ${
                error instanceof Error ? error.message : 'An error occurred'
              }`,
            });
          }
        },
      });
    },
    [
      confirm,
      addNotification,
      deleteFn,
      entityLabel,
      deleteMessage,
      confirmLabel,
      successLabel,
      errorLabel,
    ],
  );

  return {
    showFormModal,
    editEntity,
    refreshKey,
    handleCreate,
    handleEdit,
    handleDeleteClick,
    handleSaved,
    closeForm,
    triggerRefresh,
    confirm,
    ConfirmationDialog,
  };
}
