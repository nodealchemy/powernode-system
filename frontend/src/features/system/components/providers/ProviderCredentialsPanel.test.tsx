import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ProviderCredentialsPanel } from './ProviderCredentialsPanel';
import type { SystemProviderCredential } from '@system/features/system/types/system.types';

// IMP-18832c3c6128 — provider_credentials #index and #destroy had no caller in
// either frontend tree. A credential could be stored and then never seen or
// removed, which is the worst shape for credential material: "delete the one I
// just typed wrong" was the ordinary case and had no answer short of database
// access.

const mockList = jest.fn();
const mockDestroy = jest.fn();

jest.mock('@system/features/system/services/api/providerCredentialsApi', () => ({
  providerCredentialsApi: {
    list: (...args: unknown[]) => mockList(...args),
    destroy: (...args: unknown[]) => mockDestroy(...args),
  },
}));

let mockHasPermission = jest.fn((_permission: string) => true);

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (permission: string) => mockHasPermission(permission),
  }),
}));

const mockAddNotification = jest.fn();

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: mockAddNotification }),
}));

const credential = (over: Partial<SystemProviderCredential> = {}): SystemProviderCredential => ({
  id: 'cred-1',
  provider_id: 'p-1',
  provider_name: 'AWS Prod',
  provider_type: 'aws',
  name: 'aws-root-key',
  scope: 'account_owned',
  is_active: true,
  last_test_at: null,
  last_test_status: null,
  last_error: null,
  consecutive_failures: 0,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-01T00:00:00Z',
  ...over,
});

const only = (...granted: string[]) =>
  jest.fn((permission: string) => granted.includes(permission));

describe('ProviderCredentialsPanel', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockHasPermission = jest.fn(() => true);
    mockList.mockResolvedValue([credential()]);
    mockDestroy.mockResolvedValue(undefined);
  });

  it('lists the stored credentials', async () => {
    render(<ProviderCredentialsPanel />);

    expect(await screen.findByText('aws-root-key')).toBeInTheDocument();
    expect(screen.getByText('AWS Prod')).toBeInTheDocument();
    expect(mockList).toHaveBeenCalledTimes(1);
  });

  it('keeps a deactivated credential visible, marked and not removable', async () => {
    // #destroy is not the only writer of is_active: a credential deactivates
    // itself after six consecutive failures. Filtering those out would hide
    // the row on the one screen that explains why provisioning stopped, which
    // is the same one-way shape this panel exists to close.
    mockList.mockResolvedValue([
      credential({ id: 'cred-1', name: 'live-key' }),
      credential({ id: 'cred-2', name: 'burnt-key', is_active: false }),
    ]);

    render(<ProviderCredentialsPanel />);

    expect(await screen.findByText('burnt-key')).toBeInTheDocument();
    expect(screen.getByText('Deactivated')).toBeInTheDocument();
    expect(screen.getByText('Active')).toBeInTheDocument();

    // Only the live one offers a remove action.
    expect(screen.getByLabelText('Remove live-key (AWS Prod)')).toBeInTheDocument();
    expect(screen.queryByLabelText('Remove burnt-key (AWS Prod)')).not.toBeInTheDocument();
  });

  it('never renders last_error, which can quote what the operator typed', async () => {
    mockList.mockResolvedValue([
      credential({
        is_active: false,
        last_error: 'InvalidClientTokenId: the security token AKIA-TYPO is invalid',
      }),
    ]);

    render(<ProviderCredentialsPanel />);

    await screen.findByText('aws-root-key');
    expect(screen.queryByText(/AKIA-TYPO/)).not.toBeInTheDocument();
  });

  it('deletes a credential through the shared confirmation and re-reads the list', async () => {
    render(<ProviderCredentialsPanel />);

    fireEvent.click(await screen.findByLabelText('Remove aws-root-key (AWS Prod)'));

    // The shared confirmation stands between the click and the request: the
    // delete must not fire until it is confirmed.
    expect(mockDestroy).not.toHaveBeenCalled();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove credential' }));

    await waitFor(() => expect(mockDestroy).toHaveBeenCalledWith('cred-1'));
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
    expect(mockAddNotification).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'success' }),
    );
  });

  it('reports a failed delete without dropping the row or re-reading', async () => {
    mockDestroy.mockRejectedValue(new Error('credential is in use'));

    render(<ProviderCredentialsPanel />);
    await screen.findByText('aws-root-key');
    fireEvent.click(screen.getByLabelText('Remove aws-root-key (AWS Prod)'));
    fireEvent.click(await screen.findByRole('button', { name: 'Remove credential' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'credential is in use' }),
      ),
    );
    expect(screen.getByText('aws-root-key')).toBeInTheDocument();
    // Nothing changed server-side, so the refetch must not run: it would
    // pass whether or not the delete was inside the try.
    expect(mockList).toHaveBeenCalledTimes(1);
  });

  it('prefers the server sentence over the axios status line', async () => {
    // apiErrorMessage reads response.data.error; err.message here is the
    // generic Axios text, which is what the operator must NOT be shown.
    mockDestroy.mockRejectedValue(
      Object.assign(new Error('Request failed with status code 422'), {
        response: { data: { error: 'Credential is attached to a running instance' } },
      }),
    );

    render(<ProviderCredentialsPanel />);
    fireEvent.click(await screen.findByLabelText('Remove aws-root-key (AWS Prod)'));
    fireEvent.click(await screen.findByRole('button', { name: 'Remove credential' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({
          type: 'error',
          message: 'Credential is attached to a running instance',
        }),
      ),
    );
  });

  it('surfaces a failed load through the shared error alert', async () => {
    mockList.mockRejectedValue(new Error('boom'));

    render(<ProviderCredentialsPanel />);

    expect(await screen.findByText('boom')).toBeInTheDocument();
  });

  it('offers no delete action without system.providers.delete', async () => {
    mockHasPermission = only('system.providers.read');

    render(<ProviderCredentialsPanel />);

    expect(await screen.findByText('aws-root-key')).toBeInTheDocument();
    expect(screen.queryByLabelText(/^Remove /)).not.toBeInTheDocument();
  });

  it('renders nothing, and asks for nothing, without system.providers.read', () => {
    // #index answers 403 without this permission. Rendering the panel would
    // turn a permission the operator does not have into a failed request they
    // cannot act on.
    mockHasPermission = only('system.providers.delete');

    const { container } = render(<ProviderCredentialsPanel />);

    expect(container).toBeEmptyDOMElement();
    expect(mockList).not.toHaveBeenCalled();
  });

  it('re-reads when the parent bumps refreshKey', async () => {
    const { rerender } = render(<ProviderCredentialsPanel refreshKey={0} />);
    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(1));

    rerender(<ProviderCredentialsPanel refreshKey={1} />);

    await waitFor(() => expect(mockList).toHaveBeenCalledTimes(2));
  });
});
