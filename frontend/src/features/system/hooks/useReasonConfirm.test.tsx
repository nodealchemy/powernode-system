import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { useReasonConfirm } from './useReasonConfirm';

/**
 * useReasonConfirm is the replacement for the `window.prompt(msg, '')` pattern
 * that six operator panels used to capture an optional reason before a
 * destructive federation / ACME / storage action (IMP-e5cba23c32fd).
 *
 * The contract it has to hold, and that these specs pin:
 *   - the reason the operator TYPES is what reaches onConfirm;
 *   - cancelling does not run onConfirm at all (window.prompt returned null);
 *   - an empty reason arrives as undefined, not '', because every caller
 *     forwards it straight to an API client whose reason param is optional.
 *
 * The typing case is the one that matters. useConfirmation snapshots the
 * `message` element when confirm() is called and re-renders that same element
 * for the life of the dialog, so a controlled field driven by the CALLER's
 * state can never show what was typed. The field has to own its state and push
 * it outward. A spec that only asserted "onConfirm ran" would pass on the
 * broken version.
 */

const onConfirm = jest.fn();

const Harness: React.FC<{ onConfirmSpy: (reason?: string) => void }> = ({ onConfirmSpy }) => {
  const { confirmWithReason, ConfirmationDialog } = useReasonConfirm();

  return (
    <div>
      <button
        type="button"
        onClick={() =>
          confirmWithReason({
            title: 'Revoke peer',
            message: 'This is terminal.',
            confirmLabel: 'Revoke',
            variant: 'danger',
            onConfirm: onConfirmSpy,
          })
        }
      >
        Open revoke dialog
      </button>
      {ConfirmationDialog}
    </div>
  );
};

function open() {
  render(<Harness onConfirmSpy={onConfirm} />);
  fireEvent.click(screen.getByRole('button', { name: /open revoke dialog/i }));
}

describe('useReasonConfirm', () => {
  beforeEach(() => {
    onConfirm.mockReset();
  });

  it('renders nothing until the caller asks to confirm', () => {
    render(<Harness onConfirmSpy={onConfirm} />);
    expect(screen.queryByText('This is terminal.')).not.toBeInTheDocument();
  });

  it('shows the title and message once opened', async () => {
    open();
    expect(await screen.findByText('This is terminal.')).toBeInTheDocument();
    expect(screen.getByText('Revoke peer')).toBeInTheDocument();
  });

  it('offers a reason field', async () => {
    open();
    expect(await screen.findByText(/reason \(optional\)/i)).toBeInTheDocument();
    expect(document.querySelector('textarea')).toBeInTheDocument();
  });

  it('forwards the reason the operator actually typed', async () => {
    open();
    await screen.findByText(/reason \(optional\)/i);
    const field = document.querySelector('textarea') as HTMLTextAreaElement;
    fireEvent.change(field, { target: { value: 'compromised key' } });

    // The snapshotting failure mode shows up HERE: on a controlled field driven
    // by caller state the value never changes, so this assertion is the oracle.
    expect(field).toHaveValue('compromised key');

    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }));
    await waitFor(() => expect(onConfirm).toHaveBeenCalledWith('compromised key'));
  });

  it('passes undefined rather than an empty string when no reason is typed', async () => {
    open();
    await screen.findByText(/reason \(optional\)/i);

    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }));
    await waitFor(() => expect(onConfirm).toHaveBeenCalledWith(undefined));
  });

  it('does NOT run onConfirm when the operator cancels', async () => {
    open();
    await screen.findByText(/reason \(optional\)/i);

    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));

    await waitFor(() => expect(screen.queryByText('This is terminal.')).not.toBeInTheDocument());
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it('does not carry a reason over from a previous confirmation', async () => {
    render(<Harness onConfirmSpy={onConfirm} />);

    fireEvent.click(screen.getByRole('button', { name: /open revoke dialog/i }));
    await screen.findByText(/reason \(optional\)/i);
    const field = document.querySelector('textarea') as HTMLTextAreaElement;
    fireEvent.change(field, { target: { value: 'first reason' } });
    fireEvent.click(screen.getByRole('button', { name: /cancel/i }));
    await waitFor(() => expect(screen.queryByText('This is terminal.')).not.toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: /open revoke dialog/i }));
    await screen.findByText(/reason \(optional\)/i);
    fireEvent.click(screen.getByRole('button', { name: 'Revoke' }));

    await waitFor(() => expect(onConfirm).toHaveBeenCalledWith(undefined));
  });
});
