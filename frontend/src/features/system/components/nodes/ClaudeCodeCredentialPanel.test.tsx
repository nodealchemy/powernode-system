import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ClaudeCodeCredentialPanel } from './ClaudeCodeCredentialPanel';

// =============================================================================
// Mocks
// =============================================================================

const mockHasPermission = jest.fn().mockReturnValue(true);
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({ hasPermission: (...a: unknown[]) => mockHasPermission(...a) }),
}));

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({ addNotification: mockAddNotification, showNotification: jest.fn() }),
}));

const mockGetCredential = jest.fn();
const mockSetCredential = jest.fn();
const mockRotateCredential = jest.fn();
const mockDeleteCredential = jest.fn();
jest.mock('@system/features/system/services/systemApi', () => ({
  systemApi: {
    getClaudeCodeCredential: (...a: unknown[]) => mockGetCredential(...a),
    setClaudeCodeCredential: (...a: unknown[]) => mockSetCredential(...a),
    rotateClaudeCodeCredential: (...a: unknown[]) => mockRotateCredential(...a),
    deleteClaudeCodeCredential: (...a: unknown[]) => mockDeleteCredential(...a),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const CREDENTIAL = {
  id: 'cred-1',
  node_instance_id: 'inst-1',
  credential_kind: 'api_key' as const,
  configured: true,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-02-01T00:00:00Z',
};

// apiClient rejects with the raw AxiosError: `.message` is only the status
// line, and the server's own sentence lives in the error envelope. Fixtures
// must use that shape or they bless a message the client can never receive.
function apiError(status: number, serverMessage: string) {
  return Object.assign(new Error(`Request failed with status code ${status}`), {
    response: { status, data: { success: false, error: serverMessage } },
  });
}

// A value that must never appear in the DOM after it is submitted.
const SECRET = 'sk-ant-do-not-render-me';
const OAUTH_SECRET_TOKEN = 'oauth-access-do-not-render-me';
const OAUTH_JSON = JSON.stringify({
  accessToken: OAUTH_SECRET_TOKEN,
  refreshToken: 'refresh-value',
  expiresAt: 1780000000000,
});

function renderPanel(nodeId = 'node-a', instanceId = 'inst-1') {
  return render(<ClaudeCodeCredentialPanel nodeId={nodeId} instanceId={instanceId} />);
}

const apiKeyInput = () => screen.getByLabelText('API key') as HTMLInputElement;
const oauthInput = () => screen.getByLabelText('claudeAiOauth JSON') as HTMLTextAreaElement;

// =============================================================================
// Tests
// =============================================================================

describe('ClaudeCodeCredentialPanel', () => {
  beforeEach(() => {
    mockGetCredential.mockReset().mockResolvedValue(null);
    mockSetCredential.mockReset().mockResolvedValue(CREDENTIAL);
    mockRotateCredential.mockReset().mockResolvedValue(CREDENTIAL);
    mockDeleteCredential.mockReset().mockResolvedValue(undefined);
    mockAddNotification.mockReset();
    mockHasPermission.mockReset().mockReturnValue(true);
  });

  // ---------------------------------------------------------------------------
  // Status — the index card only
  // ---------------------------------------------------------------------------

  it('surfaces a non-credential 404 as an error, not as "not configured"', async () => {
    // set_node and set_instance render 404 too. The client only collapses the
    // credential's own 404, so this must reach the operator as a failure.
    mockGetCredential.mockRejectedValue(apiError(404, 'Node Instance not found'));
    renderPanel();

    await waitFor(() => expect(screen.getByText('Node Instance not found')).toBeInTheDocument());
    expect(screen.queryByText('Not configured')).not.toBeInTheDocument();
  });

  it('reports "Not configured" when the instance has no credential', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());
    expect(mockGetCredential).toHaveBeenCalledWith('node-a', 'inst-1');
  });

  it('reports the kind and last-changed time when one is configured', async () => {
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    renderPanel();

    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());
    expect(screen.getByText('api_key')).toBeInTheDocument();
    expect(screen.getByText(/Last changed/)).toBeInTheDocument();
  });

  it('shows a load failure rather than claiming nothing is configured', async () => {
    mockGetCredential.mockRejectedValue(apiError(403, 'Insufficient permissions'));
    renderPanel();

    await waitFor(() => expect(screen.getByText('Insufficient permissions')).toBeInTheDocument());
    expect(screen.queryByText('Not configured')).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  it('renders nothing without the read permission, and never asks for the credential', () => {
    mockHasPermission.mockImplementation((p: string) => p !== 'system.node_instance_credentials.read');
    const { container } = renderPanel();

    expect(container).toBeEmptyDOMElement();
    expect(mockGetCredential).not.toHaveBeenCalled();
  });

  it('is read-only without the manage permission', async () => {
    mockHasPermission.mockImplementation((p: string) => p !== 'system.node_instance_credentials.manage');
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    renderPanel();

    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());
    expect(screen.queryByRole('button', { name: 'Rotate' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Remove' })).not.toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Write-only discipline — the point of the panel
  // ---------------------------------------------------------------------------

  it('masks the API key field', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));

    expect(apiKeyInput()).toHaveAttribute('type', 'password');
    // "new-password", not "off": Chrome ignores "off" on a password field.
    expect(apiKeyInput()).toHaveAttribute('autocomplete', 'new-password');
  });

  it('sends the API key and then holds none of it in the DOM', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));

    await waitFor(() =>
      expect(mockSetCredential).toHaveBeenCalledWith('node-a', 'inst-1', { api_key: SECRET }),
    );

    // Nothing on screen, in any input's live value, still carries it. Note the
    // form also unmounts on success, so the LOAD-BEARING proof that state was
    // cleared is the failure-path spec below plus the kind-switch one — where
    // the field stays mounted and an uncleared value would be visible.
    await waitFor(() => expect(document.body.innerHTML).not.toContain(SECRET));
    expect(screen.queryByDisplayValue(SECRET)).not.toBeInTheDocument();
  });

  it('drops the typed key even when the server refuses it', async () => {
    mockSetCredential.mockRejectedValue(apiError(422, 'expiresAt is required and must be an integer'));
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));

    // The field-level sentence the controller wrote, not "Request failed with
    // status code 422" — reading err.message would throw the useful half away.
    await waitFor(() =>
      expect(screen.getByText('expiresAt is required and must be an integer')).toBeInTheDocument(),
    );
    expect(document.body.innerHTML).not.toContain(SECRET);
    expect(apiKeyInput().value).toBe('');
  });

  it('drops the pasted OAuth blob after submitting it', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(screen.getByLabelText('Credential kind'), { target: { value: 'oauth' } });
    fireEvent.change(oauthInput(), { target: { value: OAUTH_JSON } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));

    await waitFor(() =>
      expect(mockSetCredential).toHaveBeenCalledWith('node-a', 'inst-1', {
        oauth: { accessToken: OAUTH_SECRET_TOKEN, refreshToken: 'refresh-value', expiresAt: 1780000000000 },
      }),
    );
    await waitFor(() => expect(document.body.innerHTML).not.toContain(OAUTH_SECRET_TOKEN));
  });

  it('drops the typed key when the form is cancelled', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));

    expect(document.body.innerHTML).not.toContain(SECRET);
    expect(mockSetCredential).not.toHaveBeenCalled();
  });

  // Switching away unmounts the field, so an innerHTML check alone would pass
  // even if the value survived in state. Switching BACK re-mounts it, which is
  // what actually proves the state was cleared.
  it('drops the typed key when the kind is switched, and does not restore it', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });
    fireEvent.change(screen.getByLabelText('Credential kind'), { target: { value: 'oauth' } });

    expect(document.body.innerHTML).not.toContain(SECRET);

    fireEvent.change(screen.getByLabelText('Credential kind'), { target: { value: 'api_key' } });
    expect(apiKeyInput().value).toBe('');
    expect(document.body.innerHTML).not.toContain(SECRET);
  });

  it('never reopens the form pre-filled with a previous value', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));
    await waitFor(() => expect(mockSetCredential).toHaveBeenCalled());

    fireEvent.click(screen.getByRole('button', { name: 'Rotate' }));
    expect(apiKeyInput().value).toBe('');
  });

  // ---------------------------------------------------------------------------
  // Validation happens before anything is sent
  // ---------------------------------------------------------------------------

  it('refuses an empty API key without calling the API', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));

    expect(screen.getByText('An API key is required.')).toBeInTheDocument();
    expect(mockSetCredential).not.toHaveBeenCalled();
  });

  // A parser message can quote the offending input, which here is the secret.
  it('reports malformed OAuth JSON without echoing what was pasted', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(screen.getByLabelText('Credential kind'), { target: { value: 'oauth' } });
    fireEvent.change(oauthInput(), { target: { value: `{"accessToken": "${OAUTH_SECRET_TOKEN}"` } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));

    expect(screen.getByText(/not valid JSON/)).toBeInTheDocument();
    expect(mockSetCredential).not.toHaveBeenCalled();
    // The error text itself must not carry the token through.
    const error = screen.getByText(/not valid JSON/);
    expect(error.textContent).not.toContain(OAUTH_SECRET_TOKEN);
  });

  it('refuses a JSON array as an OAuth payload', async () => {
    renderPanel();
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(screen.getByLabelText('Credential kind'), { target: { value: 'oauth' } });
    fireEvent.change(oauthInput(), { target: { value: '[]' } });
    fireEvent.click(screen.getByRole('button', { name: 'Store credential' }));

    expect(screen.getByText('The OAuth payload must be a JSON object.')).toBeInTheDocument();
    expect(mockSetCredential).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Rotate
  // ---------------------------------------------------------------------------

  it('rotates rather than creates when a credential already exists', async () => {
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    renderPanel();
    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Rotate' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });
    fireEvent.click(screen.getByRole('button', { name: 'Rotate credential' }));

    await waitFor(() =>
      expect(mockRotateCredential).toHaveBeenCalledWith('node-a', 'inst-1', { api_key: SECRET }),
    );
    expect(mockSetCredential).not.toHaveBeenCalled();
    await waitFor(() => expect(document.body.innerHTML).not.toContain(SECRET));
  });

  // The server refuses a kind switch on rotate so the old kind's Vault entry is
  // never orphaned; the form must not offer one.
  it('locks the kind selector while rotating an existing credential', async () => {
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    renderPanel();
    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Rotate' }));

    expect(screen.getByLabelText('Credential kind')).toBeDisabled();
    expect(screen.getByText(/remove the credential and set a new one/i)).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Remove
  // ---------------------------------------------------------------------------

  it('confirms before removing, and does not call the API until confirmed', async () => {
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    renderPanel();
    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Remove' }));

    expect(screen.getByText('Remove Claude Code credential')).toBeInTheDocument();
    expect(mockDeleteCredential).not.toHaveBeenCalled();
  });

  it('removes once confirmed and falls back to the not-configured state', async () => {
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    renderPanel();
    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Remove' }));
    fireEvent.click(screen.getByRole('button', { name: 'Remove credential' }));

    await waitFor(() => expect(mockDeleteCredential).toHaveBeenCalledWith('node-a', 'inst-1'));
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());
  });

  it('keeps the credential on screen when the removal fails', async () => {
    mockGetCredential.mockResolvedValue(CREDENTIAL);
    mockDeleteCredential.mockRejectedValue(new Error('Vault unavailable'));
    renderPanel();
    await waitFor(() => expect(screen.getByText('Configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Remove' }));
    fireEvent.click(screen.getByRole('button', { name: 'Remove credential' }));

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(expect.objectContaining({ type: 'error' })),
    );
    expect(screen.getByText('Configured')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // The panel is reused across instances
  // ---------------------------------------------------------------------------

  it('re-reads status and drops a half-typed secret when the instance changes', async () => {
    const { rerender } = renderPanel('node-a', 'inst-1');
    await waitFor(() => expect(screen.getByText('Not configured')).toBeInTheDocument());

    fireEvent.click(screen.getByRole('button', { name: 'Set credential' }));
    fireEvent.change(apiKeyInput(), { target: { value: SECRET } });

    rerender(<ClaudeCodeCredentialPanel nodeId="node-a" instanceId="inst-2" />);

    await waitFor(() => expect(mockGetCredential).toHaveBeenCalledWith('node-a', 'inst-2'));
    expect(document.body.innerHTML).not.toContain(SECRET);
  });
});
