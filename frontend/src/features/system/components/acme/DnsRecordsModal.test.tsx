import React from 'react';
import { render, screen, fireEvent, waitFor, within } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { DnsRecordsModal } from './DnsRecordsModal';
import type { CloudflareZone, DnsRecord } from '../../types/dns.types';

// =============================================================================
// Mocks
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Minimal Modal stub — passes isOpen, children, footer, title through so we
// can query all rendered elements without a real portal.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    footer,
    title,
  }: {
    isOpen: boolean;
    children: React.ReactNode;
    footer?: React.ReactNode;
    title?: React.ReactNode;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        <div data-testid="modal-title">{title}</div>
        <div data-testid="modal-body">{children}</div>
        {footer && <div data-testid="modal-footer">{footer}</div>}
      </div>
    );
  },
}));

jest.mock('@/shared/components/ui/Button', () => ({
  Button: ({
    children,
    onClick,
    disabled,
    variant,
  }: {
    children: React.ReactNode;
    onClick?: () => void;
    disabled?: boolean;
    variant?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant}>
      {children}
    </button>
  ),
}));

// dnsRecordsApi is the surface this component uses exclusively — mock it
// directly to avoid mocking apiClient and helpers indirectly.
const mockListZones = jest.fn();
const mockListRecords = jest.fn();
const mockCreateRecord = jest.fn();
const mockUpdateRecord = jest.fn();
const mockDeleteRecord = jest.fn();

jest.mock('@system/features/system/services/api/dnsRecordsApi', () => ({
  dnsRecordsApi: {
    listZones: (...args: unknown[]) => mockListZones(...args),
    listRecords: (...args: unknown[]) => mockListRecords(...args),
    createRecord: (...args: unknown[]) => mockCreateRecord(...args),
    updateRecord: (...args: unknown[]) => mockUpdateRecord(...args),
    deleteRecord: (...args: unknown[]) => mockDeleteRecord(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const ZONE_A: CloudflareZone = {
  id: 'zone-alpha',
  name: 'alpha.example.org',
  status: 'active',
};

const ZONE_B: CloudflareZone = {
  id: 'zone-beta',
  name: 'beta.example.org',
  status: 'pending',
};

const RECORD_A: DnsRecord = {
  id: 'rec-1',
  zone_id: 'zone-alpha',
  type: 'A',
  name: 'hub.alpha.example.org',
  content: '192.0.2.1',
  ttl: 1,
  proxied: true,
};

const RECORD_B: DnsRecord = {
  id: 'rec-2',
  zone_id: 'zone-alpha',
  type: 'CNAME',
  name: 'www.alpha.example.org',
  content: 'hub.alpha.example.org',
  ttl: 300,
  proxied: false,
};

const RECORD_TXT: DnsRecord = {
  id: 'rec-3',
  zone_id: 'zone-alpha',
  type: 'TXT',
  name: 'alpha.example.org',
  content: 'v=spf1 include:_spf.google.com ~all',
  ttl: 3600,
  proxied: false,
};

// =============================================================================
// Helpers
// =============================================================================

interface RenderProps {
  isOpen?: boolean;
  credentialId?: string | null;
  credentialName?: string;
  onClose?: () => void;
}

const renderModal = (overrides: RenderProps = {}) => {
  const props = {
    isOpen: true,
    credentialId: 'cred-42',
    credentialName: 'prod-cloudflare',
    onClose: jest.fn(),
    ...overrides,
  };
  return {
    ...render(
      <BrowserRouter>
        <DnsRecordsModal {...props} />
      </BrowserRouter>,
    ),
    onClose: props.onClose,
  };
};

// =============================================================================
// Tests
// =============================================================================

describe('DnsRecordsModal', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    // Default: no zones, no records
    mockListZones.mockResolvedValue([]);
    mockListRecords.mockResolvedValue([]);
    // Suppress window.confirm noise — individual tests override as needed
    jest.spyOn(window, 'confirm').mockReturnValue(false);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  // ===========================================================================
  // Render / gate
  // ===========================================================================

  describe('null gate', () => {
    it('renders nothing when credentialId is null', () => {
      renderModal({ credentialId: null });
      expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
    });

    it('renders nothing when isOpen is false', () => {
      renderModal({ isOpen: false });
      expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
    });
  });

  describe('initial render', () => {
    it('shows the credential name in the modal title', async () => {
      renderModal({ credentialName: 'my-cf-token' });
      await waitFor(() => expect(screen.getByTestId('modal-title')).toBeInTheDocument());
      expect(screen.getByTestId('modal-title')).toHaveTextContent('my-cf-token');
    });

    it('calls listZones with the credentialId on open', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal({ credentialId: 'cred-42' });
      await waitFor(() => expect(mockListZones).toHaveBeenCalledWith('cred-42'));
    });

    it('shows the Close button in the footer', async () => {
      renderModal();
      await waitFor(() => expect(screen.getByTestId('modal-footer')).toBeInTheDocument());
      expect(within(screen.getByTestId('modal-footer')).getByText('Close')).toBeInTheDocument();
    });
  });

  // ===========================================================================
  // Zone loading
  // ===========================================================================

  describe('zone selector', () => {
    it('renders zone options from the API response', async () => {
      mockListZones.mockResolvedValue([ZONE_A, ZONE_B]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        expect(screen.getByRole('option', { name: /alpha\.example\.org \(active\)/i })).toBeInTheDocument(),
      );
      expect(screen.getByRole('option', { name: /beta\.example\.org \(pending\)/i })).toBeInTheDocument();
    });

    it('auto-selects the first zone returned', async () => {
      mockListZones.mockResolvedValue([ZONE_A, ZONE_B]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() => expect(mockListRecords).toHaveBeenCalled());
      // Records were fetched for the first zone automatically
      expect(mockListRecords).toHaveBeenCalledWith('cred-42', 'zone-alpha');
    });

    it('shows "No zones available" when the zone list is empty', async () => {
      mockListZones.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        expect(screen.getByRole('option', { name: 'No zones available' })).toBeInTheDocument(),
      );
    });

    it('fires addNotification(error) when listZones rejects', async () => {
      mockListZones.mockRejectedValue(new Error('CF token invalid'));
      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'CF token invalid' }),
        ),
      );
    });

    it('fires addNotification with fallback message when error has no message', async () => {
      mockListZones.mockRejectedValue('boom');
      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Failed to load zones' }),
        ),
      );
    });

    it('calls listRecords when the zone selector changes', async () => {
      mockListZones.mockResolvedValue([ZONE_A, ZONE_B]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      // Wait for zones to render
      await waitFor(() =>
        expect(screen.getByRole('option', { name: /beta\.example\.org/i })).toBeInTheDocument(),
      );

      const select = screen.getByRole('combobox');
      fireEvent.change(select, { target: { value: 'zone-beta' } });

      await waitFor(() =>
        expect(mockListRecords).toHaveBeenCalledWith('cred-42', 'zone-beta'),
      );
    });
  });

  // ===========================================================================
  // Record loading
  // ===========================================================================

  describe('records table', () => {
    it('renders a row for each DNS record returned', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A, RECORD_B]);
      renderModal();

      await waitFor(() =>
        expect(screen.getAllByText('hub.alpha.example.org').length).toBeGreaterThan(0),
      );
      expect(screen.getAllByText('www.alpha.example.org').length).toBeGreaterThan(0);
      expect(screen.getByText('192.0.2.1')).toBeInTheDocument();
    });

    it('shows "auto" for TTL=1 records', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]); // RECORD_A has ttl:1
      renderModal();

      await waitFor(() => expect(screen.getByText('auto')).toBeInTheDocument());
    });

    it('shows the numeric TTL for non-auto records', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]); // RECORD_B has ttl:300
      renderModal();

      await waitFor(() => expect(screen.getByText('300')).toBeInTheDocument());
    });

    it('shows "proxied" label for proxied records', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]); // proxied:true
      renderModal();

      await waitFor(() => expect(screen.getByText('proxied')).toBeInTheDocument());
    });

    it('shows "—" for non-proxied records', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]); // proxied:false
      renderModal();

      await waitFor(() => expect(screen.getByText('—')).toBeInTheDocument());
    });

    it('shows empty-state message when no records exist', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('No DNS records on this zone yet.')).toBeInTheDocument(),
      );
    });

    it('fires addNotification(error) when listRecords rejects', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockRejectedValue(new Error('Zone unreachable'));
      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Zone unreachable' }),
        ),
      );
    });

    it('fires addNotification with fallback message when listRecords error has no message', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockRejectedValue('oops');
      renderModal();

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'Failed to load records' }),
        ),
      );
    });

    it('shows "Loading records…" while records are being fetched', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      // Never resolve so we can catch the loading state
      mockListRecords.mockReturnValue(new Promise(() => undefined));
      renderModal();

      await waitFor(() =>
        expect(screen.getByText('Loading records…')).toBeInTheDocument(),
      );
    });
  });

  // ===========================================================================
  // Refresh button
  // ===========================================================================

  describe('refresh button', () => {
    it('re-calls listZones and listRecords when clicked', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]);
      renderModal();

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());

      const callsBefore = mockListZones.mock.calls.length;
      const recordCallsBefore = mockListRecords.mock.calls.length;

      fireEvent.click(screen.getByTitle('Refresh'));

      await waitFor(() => expect(mockListZones.mock.calls.length).toBeGreaterThan(callsBefore));
      await waitFor(() => expect(mockListRecords.mock.calls.length).toBeGreaterThan(recordCallsBefore));
    });
  });

  // ===========================================================================
  // Close / lifecycle
  // ===========================================================================

  describe('close behavior', () => {
    it('calls onClose when the Close button is clicked', async () => {
      mockListZones.mockResolvedValue([]);
      const { onClose } = renderModal();

      await waitFor(() => expect(screen.getByTestId('modal-footer')).toBeInTheDocument());
      fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Close'));

      expect(onClose).toHaveBeenCalledTimes(1);
    });

    it('resets zones and records when isOpen transitions to false', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]);
      const { rerender } = renderModal({ isOpen: true });

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());

      rerender(
        <BrowserRouter>
          <DnsRecordsModal
            isOpen={false}
            credentialId="cred-42"
            credentialName="prod-cloudflare"
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
    });

    it('re-fetches zones when credentialId changes while open', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      const { rerender } = renderModal({ credentialId: 'cred-1' });

      await waitFor(() => expect(mockListZones).toHaveBeenCalledWith('cred-1'));

      mockListZones.mockResolvedValue([ZONE_B]);
      rerender(
        <BrowserRouter>
          <DnsRecordsModal
            isOpen={true}
            credentialId="cred-2"
            credentialName="prod-cloudflare"
            onClose={jest.fn()}
          />
        </BrowserRouter>,
      );

      await waitFor(() => expect(mockListZones).toHaveBeenCalledWith('cred-2'));
    });
  });

  // ===========================================================================
  // Delete record
  // ===========================================================================

  describe('delete record', () => {
    it('calls deleteRecord with correct args after confirm', async () => {
      jest.spyOn(window, 'confirm').mockReturnValue(true);
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]);
      mockDeleteRecord.mockResolvedValue(undefined);
      // After deletion, listRecords is called again
      mockListRecords.mockResolvedValueOnce([RECORD_A]).mockResolvedValueOnce([]);
      renderModal();

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());

      const deleteButtons = screen.getAllByTitle('Delete record');
      fireEvent.click(deleteButtons[0]);

      await waitFor(() =>
        expect(mockDeleteRecord).toHaveBeenCalledWith('cred-42', 'rec-1', 'zone-alpha'),
      );
    });

    it('does NOT call deleteRecord when confirm returns false', async () => {
      jest.spyOn(window, 'confirm').mockReturnValue(false);
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]);
      renderModal();

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());

      fireEvent.click(screen.getByTitle('Delete record'));

      // Give any async ops a tick to settle
      await waitFor(() => expect(mockDeleteRecord).not.toHaveBeenCalled());
    });

    it('fires addNotification(error) when deleteRecord rejects', async () => {
      jest.spyOn(window, 'confirm').mockReturnValue(true);
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]);
      mockDeleteRecord.mockRejectedValue(new Error('CF delete failed'));
      renderModal();

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Delete record'));

      await waitFor(() =>
        expect(mockAddNotification).toHaveBeenCalledWith(
          expect.objectContaining({ type: 'error', message: 'CF delete failed' }),
        ),
      );
    });

    it('refreshes records after a successful delete', async () => {
      jest.spyOn(window, 'confirm').mockReturnValue(true);
      mockListZones.mockResolvedValue([ZONE_A]);
      // First load has RECORD_A; after delete, returns empty
      mockListRecords
        .mockResolvedValueOnce([RECORD_A])
        .mockResolvedValueOnce([]);
      mockDeleteRecord.mockResolvedValue(undefined);
      renderModal();

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Delete record'));

      await waitFor(() =>
        expect(screen.getByText('No DNS records on this zone yet.')).toBeInTheDocument(),
      );
    });
  });

  // ===========================================================================
  // Edit record row
  // ===========================================================================

  describe('edit record inline row', () => {
    it('switches the row to edit mode when the edit button is clicked', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]);
      renderModal();

      await waitFor(() => expect(screen.getByText('www.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));

      // Name input with current value
      expect(screen.getByDisplayValue('www.alpha.example.org')).toBeInTheDocument();
      expect(screen.getByDisplayValue('hub.alpha.example.org')).toBeInTheDocument(); // content
      expect(screen.getByTitle('Save')).toBeInTheDocument();
      expect(screen.getByTitle('Cancel')).toBeInTheDocument();
    });

    it('cancels edit mode when cancel is clicked', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]);
      renderModal();

      await waitFor(() => expect(screen.getByText('www.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));
      fireEvent.click(screen.getByTitle('Cancel'));

      // Back to read-only row
      expect(screen.queryByTitle('Save')).not.toBeInTheDocument();
      expect(screen.getByTitle('Edit record')).toBeInTheDocument();
    });

    it('calls updateRecord with the correct payload on save', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]);
      mockUpdateRecord.mockResolvedValue({ ...RECORD_B, content: 'updated.example.org' });
      mockListRecords
        .mockResolvedValueOnce([RECORD_B])
        .mockResolvedValueOnce([{ ...RECORD_B, content: 'updated.example.org' }]);
      renderModal();

      await waitFor(() => expect(screen.getByText('www.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));

      const contentInput = screen.getByDisplayValue('hub.alpha.example.org');
      fireEvent.change(contentInput, { target: { value: 'updated.example.org' } });

      fireEvent.click(screen.getByTitle('Save'));

      await waitFor(() =>
        expect(mockUpdateRecord).toHaveBeenCalledWith('cred-42', 'rec-2', {
          zone_id: 'zone-alpha',
          name: 'www.alpha.example.org',
          content: 'updated.example.org',
          ttl: 300,
          proxied: false,
        }),
      );
    });

    it('shows an inline error when updateRecord rejects', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]);
      mockUpdateRecord.mockRejectedValue(new Error('CF update failed'));
      renderModal();

      await waitFor(() => expect(screen.getByText('www.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));
      fireEvent.click(screen.getByTitle('Save'));

      await waitFor(() =>
        expect(screen.getByText('CF update failed')).toBeInTheDocument(),
      );
    });

    it('uses ttl=1 when TTL field is cleared or invalid', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_B]);
      mockUpdateRecord.mockResolvedValue(RECORD_B);
      mockListRecords
        .mockResolvedValueOnce([RECORD_B])
        .mockResolvedValueOnce([RECORD_B]);
      renderModal();

      await waitFor(() => expect(screen.getByText('www.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));

      const ttlInput = screen.getByDisplayValue('300');
      fireEvent.change(ttlInput, { target: { value: '' } });
      fireEvent.click(screen.getByTitle('Save'));

      await waitFor(() =>
        expect(mockUpdateRecord).toHaveBeenCalledWith(
          'cred-42',
          'rec-2',
          expect.objectContaining({ ttl: 1 }),
        ),
      );
    });

    it('disables the proxied checkbox for non-proxyable record types (TXT)', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_TXT]); // type: TXT
      renderModal();

      await waitFor(() => expect(screen.getByText('alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));

      const checkbox = screen.getByRole('checkbox');
      expect(checkbox).toBeDisabled();
    });

    it('enables the proxied checkbox for A records', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]); // type: A
      renderModal();

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));

      // The proxied checkbox should be enabled (not disabled) for A records
      const checkbox = screen.getByRole('checkbox');
      expect(checkbox).not.toBeDisabled();
    });

    it('refreshes records after a successful update', async () => {
      const updatedRecord = { ...RECORD_B, content: 'new-target.example.org' };
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords
        .mockResolvedValueOnce([RECORD_B])
        .mockResolvedValueOnce([updatedRecord]);
      mockUpdateRecord.mockResolvedValue(updatedRecord);
      renderModal();

      await waitFor(() => expect(screen.getByText('www.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Edit record'));
      fireEvent.click(screen.getByTitle('Save'));

      await waitFor(() =>
        expect(screen.getByText('new-target.example.org')).toBeInTheDocument(),
      );
    });
  });

  // ===========================================================================
  // Add Record form
  // ===========================================================================

  describe('Add Record form', () => {
    it('shows "Add Record" button in footer when a zone is selected', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        expect(
          within(screen.getByTestId('modal-footer')).getByText('Add Record'),
        ).toBeInTheDocument(),
      );
    });

    it('does NOT show "Add Record" button when no zone is selected', async () => {
      mockListZones.mockResolvedValue([]);
      renderModal();

      await waitFor(() => expect(screen.getByTestId('modal-footer')).toBeInTheDocument());
      expect(
        within(screen.getByTestId('modal-footer')).queryByText('Add Record'),
      ).not.toBeInTheDocument();
    });

    it('opens the add form when "Add Record" is clicked', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        expect(
          within(screen.getByTestId('modal-footer')).getByText('Add Record'),
        ).toBeInTheDocument(),
      );
      fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record'));

      expect(screen.getByText('Add DNS Record')).toBeInTheDocument();
      // Name and Content inputs identified by placeholder text
      expect(screen.getByPlaceholderText('e.g. hub.example.org')).toBeInTheDocument();
      expect(screen.getByPlaceholderText('192.0.2.1')).toBeInTheDocument(); // A record placeholder
    });

    it('hides the "Add Record" footer button while the add form is visible', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        expect(
          within(screen.getByTestId('modal-footer')).getByText('Add Record'),
        ).toBeInTheDocument(),
      );
      fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record'));

      expect(
        within(screen.getByTestId('modal-footer')).queryByText('Add Record'),
      ).not.toBeInTheDocument();
    });

    it('closes the add form when Cancel is clicked', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      // Click the Cancel button inside the form (Button component → "Cancel")
      const cancelBtn = screen.getAllByText('Cancel')[0];
      fireEvent.click(cancelBtn);

      expect(screen.queryByText('Add DNS Record')).not.toBeInTheDocument();
    });

    it('disables "Add Record" submit button when name and content are empty', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      const addBtn = screen.getByRole('button', { name: 'Add Record' });
      expect(addBtn).toBeDisabled();
    });

    it('enables the submit button when name and content are filled', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      fireEvent.change(screen.getByPlaceholderText('e.g. hub.example.org'), {
        target: { value: 'test.alpha.example.org' },
      });
      fireEvent.change(screen.getByPlaceholderText('192.0.2.1'), {
        target: { value: '192.0.2.99' },
      });

      const addBtn = screen.getByRole('button', { name: 'Add Record' });
      expect(addBtn).not.toBeDisabled();
    });

    it('shows a validation error when submitting with empty name', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      // Fill content but not name — validation.ok is false so button stays disabled
      fireEvent.change(screen.getByPlaceholderText('192.0.2.1'), {
        target: { value: '192.0.2.1' },
      });
      // name still empty → button disabled
      expect(screen.getByRole('button', { name: 'Add Record' })).toBeDisabled();
    });

    it('calls createRecord with the correct payload on submission', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      mockCreateRecord.mockResolvedValue({ ...RECORD_A, id: 'rec-new' });
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      // The add form has a type select and name/content inputs identified by placeholder
      // After selecting CNAME, the content placeholder changes to 'target.example.org'
      const typeSelects = screen.getAllByRole('combobox');
      // The add-form type select is the second combobox (first is zone selector)
      const typeSelect = typeSelects[typeSelects.length - 1];
      fireEvent.change(typeSelect, { target: { value: 'CNAME' } });

      fireEvent.change(screen.getByPlaceholderText('e.g. hub.example.org'), {
        target: { value: 'www.alpha.example.org' },
      });
      // After selecting CNAME, placeholder is 'target.example.org'
      fireEvent.change(screen.getByPlaceholderText('target.example.org'), {
        target: { value: 'target.example.org' },
      });

      fireEvent.click(screen.getByRole('button', { name: 'Add Record' }));

      await waitFor(() =>
        expect(mockCreateRecord).toHaveBeenCalledWith('cred-42', {
          zone_id: 'zone-alpha',
          type: 'CNAME',
          name: 'www.alpha.example.org',
          content: 'target.example.org',
          ttl: 1,
          proxied: false,
        }),
      );
    });

    it('forces proxied=false for non-proxyable types (TXT)', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      mockCreateRecord.mockResolvedValue({ ...RECORD_TXT, id: 'rec-new' });
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      const typeSelects = screen.getAllByRole('combobox');
      fireEvent.change(typeSelects[typeSelects.length - 1], { target: { value: 'TXT' } });

      fireEvent.change(screen.getByPlaceholderText('e.g. hub.example.org'), {
        target: { value: 'alpha.example.org' },
      });
      fireEvent.change(screen.getByPlaceholderText('v=spf1 …'), {
        target: { value: 'v=spf1 ~all' },
      });

      fireEvent.click(screen.getByRole('button', { name: 'Add Record' }));

      await waitFor(() =>
        expect(mockCreateRecord).toHaveBeenCalledWith(
          'cred-42',
          expect.objectContaining({ proxied: false, type: 'TXT' }),
        ),
      );
    });

    it('disables the proxied checkbox for TXT (non-proxyable) type', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      const typeSelects = screen.getAllByRole('combobox');
      fireEvent.change(typeSelects[typeSelects.length - 1], { target: { value: 'TXT' } });

      const checkbox = screen.getByRole('checkbox');
      expect(checkbox).toBeDisabled();
    });

    it('enables the proxied checkbox for A type', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      // Default type is A — checkbox should not be disabled
      const checkbox = screen.getByRole('checkbox');
      expect(checkbox).not.toBeDisabled();
    });

    it('shows an inline error when createRecord rejects', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      mockCreateRecord.mockRejectedValue(new Error('CF zone locked'));
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      fireEvent.change(screen.getByPlaceholderText('e.g. hub.example.org'), {
        target: { value: 'hub.alpha.example.org' },
      });
      fireEvent.change(screen.getByPlaceholderText('192.0.2.1'), {
        target: { value: '192.0.2.1' },
      });

      fireEvent.click(screen.getByRole('button', { name: 'Add Record' }));

      await waitFor(() =>
        expect(screen.getByText('CF zone locked')).toBeInTheDocument(),
      );
    });

    it('closes the form and refreshes records after a successful add', async () => {
      const newRecord: DnsRecord = {
        id: 'rec-new',
        zone_id: 'zone-alpha',
        type: 'A',
        name: 'new.alpha.example.org',
        content: '10.0.0.5',
        ttl: 1,
        proxied: false,
      };
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords
        .mockResolvedValueOnce([])
        .mockResolvedValueOnce([newRecord]);
      mockCreateRecord.mockResolvedValue(newRecord);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      fireEvent.change(screen.getByPlaceholderText('e.g. hub.example.org'), {
        target: { value: 'new.alpha.example.org' },
      });
      fireEvent.change(screen.getByPlaceholderText('192.0.2.1'), {
        target: { value: '10.0.0.5' },
      });

      fireEvent.click(screen.getByRole('button', { name: 'Add Record' }));

      // Form disappears
      await waitFor(() =>
        expect(screen.queryByText('Add DNS Record')).not.toBeInTheDocument(),
      );
      // New record appears
      await waitFor(() =>
        expect(screen.getAllByText('new.alpha.example.org').length).toBeGreaterThan(0),
      );
    });

    it('trims whitespace from name and content before submitting', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      mockCreateRecord.mockResolvedValue(RECORD_A);
      renderModal();

      await waitFor(() =>
        fireEvent.click(within(screen.getByTestId('modal-footer')).getByText('Add Record')),
      );

      fireEvent.change(screen.getByPlaceholderText('e.g. hub.example.org'), {
        target: { value: '  spaced.example.org  ' },
      });
      fireEvent.change(screen.getByPlaceholderText('192.0.2.1'), {
        target: { value: '  192.0.2.1  ' },
      });

      fireEvent.click(screen.getByRole('button', { name: 'Add Record' }));

      await waitFor(() =>
        expect(mockCreateRecord).toHaveBeenCalledWith(
          'cred-42',
          expect.objectContaining({
            name: 'spaced.example.org',
            content: '192.0.2.1',
          }),
        ),
      );
    });
  });

  // ===========================================================================
  // API URL shape verification
  // ===========================================================================

  describe('API call shapes', () => {
    it('listZones uses credential-scoped URL /system/acme_dns_credentials/:id/zones', async () => {
      mockListZones.mockResolvedValue([]);
      renderModal({ credentialId: 'cred-999' });
      await waitFor(() => expect(mockListZones).toHaveBeenCalledWith('cred-999'));
    });

    it('listRecords uses credentialId + zoneId', async () => {
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([]);
      renderModal({ credentialId: 'cred-999' });
      await waitFor(() => expect(mockListRecords).toHaveBeenCalledWith('cred-999', 'zone-alpha'));
    });

    it('deleteRecord passes zoneId as the third argument', async () => {
      jest.spyOn(window, 'confirm').mockReturnValue(true);
      mockListZones.mockResolvedValue([ZONE_A]);
      mockListRecords.mockResolvedValue([RECORD_A]);
      mockDeleteRecord.mockResolvedValue(undefined);
      mockListRecords
        .mockResolvedValueOnce([RECORD_A])
        .mockResolvedValueOnce([]);
      renderModal({ credentialId: 'cred-999' });

      await waitFor(() => expect(screen.getByText('hub.alpha.example.org')).toBeInTheDocument());
      fireEvent.click(screen.getByTitle('Delete record'));

      await waitFor(() =>
        expect(mockDeleteRecord).toHaveBeenCalledWith('cred-999', 'rec-1', 'zone-alpha'),
      );
    });
  });
});
