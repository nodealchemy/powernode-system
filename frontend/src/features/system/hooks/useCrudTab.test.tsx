import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { useCrudTab } from './useCrudTab';

/**
 * useCrudTab is the shared body of the catalog/* and compute/* CRUD tabs
 * (IMP-9fa34731baeb). Nine tabs carried the same 72–131 lines with the nouns
 * changed, so a fix to the delete flow had to be applied nine times.
 *
 * What these specs pin is the behaviour the tabs actually depend on, in the
 * places a naive extraction gets wrong:
 *
 *   - the delete runs ONLY after the operator confirms, and a failed delete
 *     does not bump refreshKey (a list that silently reloads after a failed
 *     destructive action reads as success);
 *   - the operator-visible strings are built from the label the caller gives,
 *     because nine tab specs assert those exact sentences;
 *   - handleCreate CLEARS the edit entity — otherwise "New" opens the form
 *     still holding the last-edited row and an operator edits the wrong one;
 *   - onActionsReady publishes a handle on mount and NULLS it on unmount, so a
 *     page-level "New" button never calls into an unmounted tab;
 *   - handleCreate is referentially stable, since it sits in the
 *     onActionsReady effect's dependency list.
 */

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

interface Widget {
  id: string;
  name: string;
}

const WIDGET: Widget = { id: 'w-1', name: 'first widget' };
const OTHER: Widget = { id: 'w-2', name: 'second widget' };

const onOtherConfirm = jest.fn();

interface HarnessProps {
  deleteFn: (id: string) => Promise<unknown>;
  onActionsReady?: (handle: { openCreate: () => void } | null) => void;
  entityLabel?: string;
  successLabel?: string;
  errorLabel?: string;
  confirmLabel?: string;
}

/** Renders the hook's state so each assertion reads it off the DOM. */
const Harness: React.FC<HarnessProps> = ({
  deleteFn,
  onActionsReady,
  entityLabel = 'Widget',
  successLabel,
  errorLabel,
  confirmLabel,
}) => {
  const crud = useCrudTab<Widget>({
    entityLabel,
    successLabel,
    errorLabel,
    confirmLabel,
    deleteFn,
    deleteMessage: 'Are you sure you want to delete this widget? This cannot be undone.',
    onActionsReady,
  });

  return (
    <div>
      <span data-testid="show-form">{String(crud.showFormModal)}</span>
      <span data-testid="edit-entity">{crud.editEntity?.name ?? 'none'}</span>
      <span data-testid="refresh-key">{crud.refreshKey}</span>
      <button data-testid="create" onClick={crud.handleCreate}>
        create
      </button>
      <button data-testid="edit" onClick={() => crud.handleEdit(WIDGET)}>
        edit
      </button>
      <button data-testid="edit-other" onClick={() => crud.handleEdit(OTHER)}>
        edit other
      </button>
      <button data-testid="delete" onClick={() => crud.handleDeleteClick('w-1')}>
        delete
      </button>
      <button data-testid="saved" onClick={crud.handleSaved}>
        saved
      </button>
      <button data-testid="close" onClick={crud.closeForm}>
        close
      </button>
      <button data-testid="refresh" onClick={crud.triggerRefresh}>
        refresh
      </button>
      <button
        data-testid="other-destructive"
        onClick={() =>
          crud.confirm({
            title: 'Detach Widget',
            message: 'Detach it?',
            confirmLabel: 'Detach Widget',
            variant: 'danger',
            onConfirm: () => onOtherConfirm(),
          })
        }
      >
        detach
      </button>
      {crud.ConfirmationDialog}
    </div>
  );
};

const read = (id: string) => screen.getByTestId(id).textContent;

beforeEach(() => {
  jest.clearAllMocks();
});

describe('useCrudTab', () => {
  describe('form state', () => {
    it('starts closed with no entity under edit', () => {
      render(<Harness deleteFn={jest.fn()} />);
      expect(read('show-form')).toBe('false');
      expect(read('edit-entity')).toBe('none');
    });

    it('handleEdit opens the form holding that entity', () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('edit'));
      expect(read('show-form')).toBe('true');
      expect(read('edit-entity')).toBe('first widget');
    });

    it('handleCreate opens the form and CLEARS a previously edited entity', () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('edit'));
      fireEvent.click(screen.getByTestId('close'));
      fireEvent.click(screen.getByTestId('create'));

      expect(read('show-form')).toBe('true');
      // The bug this pins: "New" opening the form still holding the last row,
      // so the operator edits an existing entity thinking they made one.
      expect(read('edit-entity')).toBe('none');
    });

    it('handleEdit replaces the entity rather than keeping the first', () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('edit'));
      fireEvent.click(screen.getByTestId('edit-other'));
      expect(read('edit-entity')).toBe('second widget');
    });

    it('closeForm closes it and drops the entity', () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('edit'));
      fireEvent.click(screen.getByTestId('close'));
      expect(read('show-form')).toBe('false');
      expect(read('edit-entity')).toBe('none');
    });

    it('handleSaved bumps refreshKey and drops the entity', () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('edit'));
      fireEvent.click(screen.getByTestId('saved'));
      expect(read('refresh-key')).toBe('1');
      expect(read('edit-entity')).toBe('none');
    });

    it('triggerRefresh bumps refreshKey for flows the hook does not own', () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('refresh'));
      fireEvent.click(screen.getByTestId('refresh'));
      expect(read('refresh-key')).toBe('2');
    });
  });

  describe('delete', () => {
    it('does not delete until the operator confirms', async () => {
      const deleteFn = jest.fn().mockResolvedValue(undefined);
      render(<Harness deleteFn={deleteFn} />);
      fireEvent.click(screen.getByTestId('delete'));

      expect(
        await screen.findByText(/Are you sure you want to delete this widget/),
      ).toBeInTheDocument();
      expect(deleteFn).not.toHaveBeenCalled();
    });

    it('calls deleteFn with the id, notifies, and refreshes on confirm', async () => {
      const deleteFn = jest.fn().mockResolvedValue(undefined);
      render(<Harness deleteFn={deleteFn} />);
      fireEvent.click(screen.getByTestId('delete'));
      fireEvent.click(await screen.findByRole('button', { name: 'Delete Widget' }));

      await waitFor(() => expect(deleteFn).toHaveBeenCalledWith('w-1'));
      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Widget deleted successfully',
        }),
      );
      await waitFor(() => expect(read('refresh-key')).toBe('1'));
    });

    it('reports a failed delete and does NOT bump refreshKey', async () => {
      const deleteFn = jest.fn().mockRejectedValue(new Error('in use by a template'));
      render(<Harness deleteFn={deleteFn} />);
      fireEvent.click(screen.getByTestId('delete'));
      fireEvent.click(await screen.findByRole('button', { name: 'Delete Widget' }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to delete widget: in use by a template',
        }),
      );
      // A list that reloads after a failed destructive action reads as success.
      expect(read('refresh-key')).toBe('0');
    });

    it('falls back to a generic sentence when the failure carries no message', async () => {
      const deleteFn = jest.fn().mockRejectedValue('not an Error');
      render(<Harness deleteFn={deleteFn} />);
      fireEvent.click(screen.getByTestId('delete'));
      fireEvent.click(await screen.findByRole('button', { name: 'Delete Widget' }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'error',
          message: 'Failed to delete widget: An error occurred',
        }),
      );
    });

    it('titles the dialog from the label', async () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('delete'));
      // "Delete Widget" is BOTH the heading and, by default, the confirm
      // button — so target the heading rather than matching either.
      expect(
        await screen.findByRole('heading', { name: 'Delete Widget' }),
      ).toBeInTheDocument();
    });

    // Puppet modules title "Delete Puppet Module" but confirm with "Delete
    // Module" and report "Puppet module deleted successfully" — three casings
    // of one noun, each pinned by a tab spec, so none may be derived.
    it('lets each operator-visible string be overridden independently', async () => {
      const deleteFn = jest.fn().mockResolvedValue(undefined);
      render(
        <Harness
          deleteFn={deleteFn}
          entityLabel="Puppet Module"
          confirmLabel="Delete Module"
          successLabel="Puppet module"
          errorLabel="Puppet module"
        />,
      );
      fireEvent.click(screen.getByTestId('delete'));

      expect(
        await screen.findByRole('heading', { name: 'Delete Puppet Module' }),
      ).toBeInTheDocument();
      fireEvent.click(screen.getByRole('button', { name: 'Delete Module' }));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith({
          type: 'success',
          message: 'Puppet module deleted successfully',
        }),
      );
    });
  });

  // A tab's own destructive action (VolumesTab's detach) must reuse this
  // hook's dialog rather than mounting a second useConfirmation, which would
  // put two dialogs in the tree.
  describe('confirm passthrough', () => {
    it('drives the same ConfirmationDialog for a non-delete destructive action', async () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('other-destructive'));

      expect(
        await screen.findByRole('heading', { name: 'Detach Widget' }),
      ).toBeInTheDocument();
      fireEvent.click(screen.getByRole('button', { name: 'Detach Widget' }));
      await waitFor(() => expect(onOtherConfirm).toHaveBeenCalled());
    });

    it('replaces the open dialog rather than stacking a second one', async () => {
      render(<Harness deleteFn={jest.fn()} />);
      fireEvent.click(screen.getByTestId('delete'));
      await screen.findByRole('heading', { name: 'Delete Widget' });

      // Open the OTHER destructive action while the first dialog is up. A
      // version that mounted a second useConfirmation would leave both
      // headings in the tree; asserting only the second one's absence before
      // ever opening it would pass against every implementation.
      fireEvent.click(screen.getByTestId('other-destructive'));
      await screen.findByRole('heading', { name: 'Detach Widget' });

      expect(screen.getAllByRole('dialog')).toHaveLength(1);
      expect(screen.queryByRole('heading', { name: 'Delete Widget' })).not.toBeInTheDocument();
    });
  });

  describe('onActionsReady', () => {
    it('publishes an openCreate handle on mount', () => {
      const onActionsReady = jest.fn();
      render(<Harness deleteFn={jest.fn()} onActionsReady={onActionsReady} />);
      expect(onActionsReady).toHaveBeenCalledWith(
        expect.objectContaining({ openCreate: expect.any(Function) }),
      );
    });

    it('nulls the handle on unmount so a stale page button cannot fire', () => {
      const onActionsReady = jest.fn();
      const { unmount } = render(
        <Harness deleteFn={jest.fn()} onActionsReady={onActionsReady} />,
      );
      onActionsReady.mockClear();
      unmount();
      expect(onActionsReady).toHaveBeenCalledWith(null);
    });

    it('the published openCreate opens the form', () => {
      let handle: { openCreate: () => void } | null = null;
      render(
        <Harness
          deleteFn={jest.fn()}
          onActionsReady={(h) => {
            if (h) handle = h;
          }}
        />,
      );
      expect(read('show-form')).toBe('false');
      act(() => handle!.openCreate());
      expect(read('show-form')).toBe('true');
    });

    // handleCreate sits in the effect's dependency list, so an unstable
    // identity re-publishes the handle on every render — which in the real
    // tabs re-runs the parent's setState and can loop.
    it('does not republish the handle on an unrelated re-render', () => {
      const onActionsReady = jest.fn();
      render(<Harness deleteFn={jest.fn()} onActionsReady={onActionsReady} />);
      const callsAfterMount = onActionsReady.mock.calls.length;

      fireEvent.click(screen.getByTestId('refresh'));
      fireEvent.click(screen.getByTestId('edit'));

      expect(onActionsReady.mock.calls.length).toBe(callsAfterMount);
    });
  });
});
