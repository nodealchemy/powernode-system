import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { OperatorKeyPanel } from './OperatorKeyPanel';

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: mockAddNotification, showNotification: jest.fn() }),
}));

const mockMint = jest.fn();
const mockRevoke = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    mintOperatorKey: (...a: unknown[]) => mockMint(...a),
    revokeOperatorKey: (...a: unknown[]) => mockRevoke(...a),
  },
}));
jest.mock('@system/features/system/services/api/nodesApi', () => ({
  apiErrorMessage: (_e: unknown, fallback: string) => fallback,
}));

const KEY = 'not-a-real-enrol-key';
const DOC = '{"version":1,"key":"not-a-real-enrol-key"}';
const MINT = {
  bootstrap_token: { id: 'tok-1', expires_at: '2026-10-21T10:00:00Z' },
  token: KEY,
  provisioning_document: DOC,
};

describe('OperatorKeyPanel', () => {
  let createObjectURL: jest.Mock;
  let revokeObjectURL: jest.Mock;
  beforeEach(() => {
    jest.clearAllMocks();
    createObjectURL = jest.fn().mockReturnValue('blob:x');
    revokeObjectURL = jest.fn();
    global.URL.createObjectURL = createObjectURL;
    global.URL.revokeObjectURL = revokeObjectURL;
    mockMint.mockResolvedValue(MINT);
    mockRevoke.mockResolvedValue(undefined);
  });

  const open = async () => {
    render(<OperatorKeyPanel nodeId="n1" instanceId="i1" />);
    fireEvent.click(screen.getByRole('button', { name: /generate enrolment key/i }));
    await screen.findByText(KEY);
  };

  it('mints with the provisioning document requested and shows the key and expiry once', async () => {
    await open();
    expect(mockMint).toHaveBeenCalledWith('n1', 'i1', { includeProvisioningDocument: true });
    expect(screen.getByText(/expires/i)).toBeInTheDocument();
  });

  it('downloads powernode-provision.cfg client-side from the one-time response', async () => {
    jest.useFakeTimers();
    const click = jest.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
    await open();
    fireEvent.click(screen.getByRole('button', { name: /download powernode-provision\.cfg/i }));
    expect(createObjectURL).toHaveBeenCalledTimes(1);
    const blob = createObjectURL.mock.calls[0][0] as Blob;
    const text = await new Promise<string>((resolve) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result));
      reader.readAsText(blob);
    });
    expect(text).toBe(DOC);
    expect(click).toHaveBeenCalled();
    // Deferred so browsers that start the download asynchronously are not cancelled.
    expect(revokeObjectURL).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1000);
    expect(revokeObjectURL).toHaveBeenCalledWith('blob:x');
    click.mockRestore();
    jest.useRealTimers();
  });

  it('revokes the key and drops the secret from the DOM', async () => {
    await open();
    fireEvent.click(screen.getByRole('button', { name: /revoke/i }));
    await waitFor(() => expect(mockRevoke).toHaveBeenCalledWith('n1', 'i1', 'tok-1'));
    expect(screen.queryByText(KEY)).not.toBeInTheDocument();
  });

  it('clears the secret when dismissed', async () => {
    await open();
    fireEvent.click(screen.getByRole('button', { name: /done/i }));
    expect(screen.queryByText(KEY)).not.toBeInTheDocument();
  });

  it('shows the server error and no key when minting is refused', async () => {
    mockMint.mockRejectedValue(new Error('x'));
    render(<OperatorKeyPanel nodeId="n1" instanceId="i1" />);
    fireEvent.click(screen.getByRole('button', { name: /generate enrolment key/i }));
    await waitFor(() => expect(mockAddNotification).toHaveBeenCalledWith(expect.objectContaining({ type: 'error' })));
    expect(screen.queryByText(KEY)).not.toBeInTheDocument();
  });
});
