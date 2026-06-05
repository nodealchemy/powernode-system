import React from 'react';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import { ServiceOfferingEditorModal } from './ServiceOfferingEditorModal';
import type { ServiceOffering } from '../../types/service_delivery.types';

// =============================================================================
// Mocks
//
// The modal is a self-contained form that calls serviceCatalogApi directly.
// We mock serviceCatalogApi at the module level and stub Modal + Button so
// the form fields and footer buttons are rendered in a flat DOM structure.
// =============================================================================

const mockAddNotification = jest.fn();
jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: mockAddNotification,
    showNotification: jest.fn(),
  }),
}));

// Render modal content + footer flat so we can query form fields and buttons.
jest.mock('@/shared/components/ui/Modal', () => ({
  Modal: ({
    isOpen,
    children,
    footer,
  }: {
    isOpen: boolean;
    title?: React.ReactNode;
    children: React.ReactNode;
    footer?: React.ReactNode;
    maxWidth?: string;
    onClose: () => void;
  }) => {
    if (!isOpen) return null;
    return (
      <div data-testid="modal">
        {children}
        {footer}
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
    onClick?: (e: React.MouseEvent) => void;
    disabled?: boolean;
    variant?: string;
  }) => (
    <button onClick={onClick} disabled={disabled} data-variant={variant}>
      {children}
    </button>
  ),
}));

const mockCreateOffering = jest.fn();
const mockUpdateOffering = jest.fn();

jest.mock('@system/features/system/services/api/serviceCatalogApi', () => ({
  serviceCatalogApi: {
    createOffering: (...args: unknown[]) => mockCreateOffering(...args),
    updateOffering: (...args: unknown[]) => mockUpdateOffering(...args),
  },
}));

// =============================================================================
// Fixtures
// =============================================================================

const BASE_OFFERING: ServiceOffering = {
  id: 'offering-1',
  slug: 'managed-postgres',
  name: 'Managed Postgres',
  protocol: 'https',
  status: 'active',
  backend_host: 'postgres.internal',
  backend_port: 5432,
  backend_vip_id: null,
  default_grant_ttl_days: 30,
  default_grant_scopes: ['read', 'write'],
  capacity_metadata: { max_subscribers: 50 },
  latency_metadata: {},
  accepting_new_subscriptions: true,
  active_subscription_count: 3,
  created_at: '2026-01-01T00:00:00Z',
  updated_at: '2026-01-02T00:00:00Z',
  description_markdown: '## Postgres\nManaged PostgreSQL service.',
  subscription_terms_markdown: 'SLA: 99.9%',
};

// =============================================================================
// Helpers
// =============================================================================

const renderModal = (
  overrides: Partial<React.ComponentProps<typeof ServiceOfferingEditorModal>> = {},
) => {
  const props = {
    isOpen: true,
    onClose: jest.fn(),
    editOffering: undefined,
    onSaved: jest.fn(),
    ...overrides,
  };
  render(
    <BrowserRouter>
      <ServiceOfferingEditorModal {...props} />
    </BrowserRouter>,
  );
  return props;
};

// =============================================================================
// Tests
// =============================================================================

describe('ServiceOfferingEditorModal', () => {
  beforeEach(() => {
    mockAddNotification.mockReset();
    mockCreateOffering.mockReset();
    mockUpdateOffering.mockReset();
  });

  // ---------------------------------------------------------------------------
  // Render states
  // ---------------------------------------------------------------------------

  it('renders nothing when isOpen is false', () => {
    renderModal({ isOpen: false });
    expect(screen.queryByTestId('modal')).not.toBeInTheDocument();
  });

  it('renders the create form with empty defaults when no editOffering provided', () => {
    renderModal();

    // Slug is editable (not disabled)
    const slugInput = screen.getByPlaceholderText(/gitea, managed-postgres/i);
    expect(slugInput).toBeInTheDocument();
    expect(slugInput).not.toBeDisabled();
    expect((slugInput as HTMLInputElement).value).toBe('');

    // Name empty
    const nameInput = screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i);
    expect((nameInput as HTMLInputElement).value).toBe('');

    // Default protocol is https
    const protoSelect = screen.getByRole('combobox');
    expect((protoSelect as HTMLSelectElement).value).toBe('https');

    // Backend port defaults to 443
    const portInput = screen.getByDisplayValue('443');
    expect(portInput).toBeInTheDocument();

    // Default TTL is 30
    const ttlInput = screen.getByDisplayValue('30');
    expect(ttlInput).toBeInTheDocument();

    // Submit button reads "Create Offering"
    expect(screen.getByRole('button', { name: 'Create Offering' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
  });

  it('renders the edit form pre-populated from editOffering', () => {
    renderModal({ editOffering: BASE_OFFERING });

    // Slug is locked (disabled)
    const slugInput = screen.getByDisplayValue('managed-postgres');
    expect(slugInput).toBeDisabled();

    // Other fields pre-populated
    expect((screen.getByDisplayValue('Managed Postgres') as HTMLInputElement).value).toBe(
      'Managed Postgres',
    );
    expect((screen.getByDisplayValue('postgres.internal') as HTMLInputElement).value).toBe(
      'postgres.internal',
    );
    expect((screen.getByDisplayValue('5432') as HTMLInputElement).value).toBe('5432');
    expect((screen.getByDisplayValue('50') as HTMLInputElement).value).toBe('50');

    // Submit button reads "Save Changes"
    expect(screen.getByRole('button', { name: 'Save Changes' })).toBeInTheDocument();
  });

  it('resets to empty defaults when reopened without editOffering after having an edit', async () => {
    const { rerender } = render(
      <BrowserRouter>
        <ServiceOfferingEditorModal
          isOpen={true}
          onClose={jest.fn()}
          editOffering={BASE_OFFERING}
          onSaved={jest.fn()}
        />
      </BrowserRouter>,
    );

    // Edit mode: slug shows the offering slug
    expect(screen.getByDisplayValue('managed-postgres')).toBeInTheDocument();

    // Close then reopen in create mode
    rerender(
      <BrowserRouter>
        <ServiceOfferingEditorModal
          isOpen={false}
          onClose={jest.fn()}
          editOffering={undefined}
          onSaved={jest.fn()}
        />
      </BrowserRouter>,
    );
    rerender(
      <BrowserRouter>
        <ServiceOfferingEditorModal
          isOpen={true}
          onClose={jest.fn()}
          editOffering={undefined}
          onSaved={jest.fn()}
        />
      </BrowserRouter>,
    );

    // Slug input should now be empty
    const slugInput = screen.getByPlaceholderText(/gitea, managed-postgres/i);
    expect((slugInput as HTMLInputElement).value).toBe('');
  });

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  it('disables the submit button when form is invalid (empty required fields)', () => {
    renderModal();
    // EMPTY_FORM has no backend_host — validation fires immediately
    const submitBtn = screen.getByRole('button', { name: 'Create Offering' });
    expect(submitBtn).toBeDisabled();
  });

  it('enables submit only when all required fields are valid', async () => {
    renderModal();

    // Fill slug
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-service' },
    });
    // Fill name
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });
    // Fill backend_host
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'svc.internal' },
    });

    // Port + TTL + scope (read) are defaulted — should be valid now
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create Offering' })).not.toBeDisabled(),
    );
  });

  it('does not call createOffering when form is invalid (no backend_host)', () => {
    renderModal();

    // Partially fill form (no backend_host)
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });

    // Submit button is disabled because backend_host is empty — API must not be called
    const submitBtn = screen.getByRole('button', { name: 'Create Offering' });
    expect(submitBtn).toBeDisabled();
    expect(mockCreateOffering).not.toHaveBeenCalled();
  });

  // ---------------------------------------------------------------------------
  // Slug validation rules
  // ---------------------------------------------------------------------------

  it('lowercases and trims slug input automatically', () => {
    renderModal();
    const slugInput = screen.getByPlaceholderText(/gitea, managed-postgres/i);
    fireEvent.change(slugInput, { target: { value: '  UPPER-Case  ' } });
    expect((slugInput as HTMLInputElement).value).toBe('upper-case');
  });

  it('keeps submit disabled for a slug that starts with a hyphen', async () => {
    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: '-bad-slug' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'Test' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    // slug '-bad-slug' does not match /^[a-z0-9][a-z0-9-]*$/ — form stays invalid
    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create Offering' })).toBeDisabled(),
    );
  });

  it('accepts a valid slug that starts with a digit', async () => {
    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: '1svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'Test' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create Offering' })).not.toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // Port validation
  // ---------------------------------------------------------------------------

  it('disables submit when port is out of range', async () => {
    renderModal({ editOffering: BASE_OFFERING });

    // Clear the port and enter 0 (below minimum)
    const portInput = screen.getByDisplayValue('5432');
    fireEvent.change(portInput, { target: { value: '0' } });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save Changes' })).toBeDisabled(),
    );
  });

  it('disables submit when port is above 65535', async () => {
    renderModal({ editOffering: BASE_OFFERING });

    const portInput = screen.getByDisplayValue('5432');
    fireEvent.change(portInput, { target: { value: '70000' } });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save Changes' })).toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // TTL validation
  // ---------------------------------------------------------------------------

  it('disables submit when Grant TTL is below 7 days', async () => {
    renderModal({ editOffering: BASE_OFFERING });

    const ttlInput = screen.getByDisplayValue('30');
    fireEvent.change(ttlInput, { target: { value: '3' } });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save Changes' })).toBeDisabled(),
    );
  });

  it('accepts Grant TTL of exactly 7 (the floor)', async () => {
    renderModal({ editOffering: BASE_OFFERING });

    const ttlInput = screen.getByDisplayValue('30');
    fireEvent.change(ttlInput, { target: { value: '7' } });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save Changes' })).not.toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // Grant scope toggle
  // ---------------------------------------------------------------------------

  it('toggles a scope off when clicked (removes it from the selection)', () => {
    renderModal();

    // Default scopes: ['read'] — 'read' button should be "active" (text-white class)
    const readBtn = screen.getByRole('button', { name: 'read' });
    expect(readBtn.className).toContain('text-white');

    // Clicking 'read' deactivates it
    fireEvent.click(readBtn);
    expect(readBtn.className).not.toContain('text-white');
  });

  it('toggles a scope on when clicked (adds it to the selection)', () => {
    renderModal();

    const writeBtn = screen.getByRole('button', { name: 'write' });
    // write is not active initially
    expect(writeBtn.className).not.toContain('text-white');

    fireEvent.click(writeBtn);
    expect(writeBtn.className).toContain('text-white');
  });

  it('disables submit when all scopes are deactivated', async () => {
    renderModal();

    // Fill required fields so the only failure is zero scopes
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'test-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'Test' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    // Deactivate 'read' (only active scope)
    fireEvent.click(screen.getByRole('button', { name: 'read' }));

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Create Offering' })).toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // Max subscribers optional field
  // ---------------------------------------------------------------------------

  it('accepts blank max_subscribers (uncapped)', async () => {
    renderModal({ editOffering: BASE_OFFERING });

    // Clear the max_subscribers value
    const maxSubsInput = screen.getByDisplayValue('50');
    fireEvent.change(maxSubsInput, { target: { value: '' } });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save Changes' })).not.toBeDisabled(),
    );
  });

  it('disables submit when max_subscribers is negative', async () => {
    renderModal({ editOffering: BASE_OFFERING });

    const maxSubsInput = screen.getByDisplayValue('50');
    fireEvent.change(maxSubsInput, { target: { value: '-1' } });

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Save Changes' })).toBeDisabled(),
    );
  });

  // ---------------------------------------------------------------------------
  // Create submission
  // ---------------------------------------------------------------------------

  it('calls serviceCatalogApi.createOffering with the correct payload on create submit', async () => {
    const onSaved = jest.fn();
    const onClose = jest.fn();
    const savedOffering: ServiceOffering = {
      ...BASE_OFFERING,
      id: 'new-id',
      slug: 'my-svc',
      name: 'My Service',
    };
    mockCreateOffering.mockResolvedValueOnce(savedOffering);

    renderModal({ onSaved, onClose });

    // Fill required fields
    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'svc.internal' },
    });
    // Override port to 8080
    const portInput = screen.getByDisplayValue('443');
    fireEvent.change(portInput, { target: { value: '8080' } });

    // Change protocol to tcp
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'tcp' } });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockCreateOffering).toHaveBeenCalledWith(
        expect.objectContaining({
          slug: 'my-svc',
          name: 'My Service',
          protocol: 'tcp',
          backend_host: 'svc.internal',
          backend_port: 8080,
          default_grant_ttl_days: 30,
          default_grant_scopes: ['read'],
        }),
      ),
    );

    // Success notification, onSaved called, modal closed
    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: expect.stringContaining('created') }),
      ),
    );
    expect(onSaved).toHaveBeenCalledWith(savedOffering);
    expect(onClose).toHaveBeenCalled();
  });

  it('does NOT include slug in the create payload — slug comes from form field', async () => {
    const savedOffering: ServiceOffering = { ...BASE_OFFERING, id: 'new-id', slug: 'test-slug' };
    mockCreateOffering.mockResolvedValueOnce(savedOffering);

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'test-slug' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'Test' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() => expect(mockCreateOffering).toHaveBeenCalled());
    const payload = mockCreateOffering.mock.calls[0][0];
    expect(payload.slug).toBe('test-slug');
  });

  it('includes description_markdown in payload only when non-empty', async () => {
    const savedOffering: ServiceOffering = { ...BASE_OFFERING, id: 'new-id', slug: 'desc-svc' };
    mockCreateOffering.mockResolvedValueOnce(savedOffering);

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'desc-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'Desc Test' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });
    // Fill description textarea
    const textareas = screen.getAllByRole('textbox');
    const descTextarea = textareas.find(
      (el) => el.tagName === 'TEXTAREA' && (el as HTMLTextAreaElement).rows === 3,
    );
    expect(descTextarea).toBeDefined();
    fireEvent.change(descTextarea!, { target: { value: '## My service' } });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() => expect(mockCreateOffering).toHaveBeenCalled());
    const payload = mockCreateOffering.mock.calls[0][0];
    expect(payload.description_markdown).toBe('## My service');
  });

  it('includes capacity_metadata when max_subscribers is provided', async () => {
    const savedOffering: ServiceOffering = { ...BASE_OFFERING, id: 'new-id', slug: 'cap-svc' };
    mockCreateOffering.mockResolvedValueOnce(savedOffering);

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'cap-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'Cap Test' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });
    fireEvent.change(screen.getByPlaceholderText(/\(uncapped\)/i), {
      target: { value: '100' },
    });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() => expect(mockCreateOffering).toHaveBeenCalled());
    const payload = mockCreateOffering.mock.calls[0][0];
    expect(payload.capacity_metadata).toEqual({ max_subscribers: 100 });
  });

  // ---------------------------------------------------------------------------
  // Edit submission
  // ---------------------------------------------------------------------------

  it('calls serviceCatalogApi.updateOffering with the correct id and payload on edit submit', async () => {
    const onSaved = jest.fn();
    const onClose = jest.fn();
    const updatedOffering: ServiceOffering = { ...BASE_OFFERING, name: 'Renamed Postgres' };
    mockUpdateOffering.mockResolvedValueOnce(updatedOffering);

    renderModal({ editOffering: BASE_OFFERING, onSaved, onClose });

    // Change name
    const nameInput = screen.getByDisplayValue('Managed Postgres');
    fireEvent.change(nameInput, { target: { value: 'Renamed Postgres' } });

    const submitBtn = await screen.findByRole('button', { name: 'Save Changes' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockUpdateOffering).toHaveBeenCalledWith(
        'offering-1',
        expect.objectContaining({
          name: 'Renamed Postgres',
          protocol: 'https',
          backend_host: 'postgres.internal',
          backend_port: 5432,
          default_grant_ttl_days: 30,
          default_grant_scopes: ['read', 'write'],
        }),
      ),
    );

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'success', message: expect.stringContaining('updated') }),
      ),
    );
    expect(onSaved).toHaveBeenCalledWith(updatedOffering);
    expect(onClose).toHaveBeenCalled();
  });

  it('does NOT include slug in the update payload (slug is immutable)', async () => {
    const updatedOffering = { ...BASE_OFFERING };
    mockUpdateOffering.mockResolvedValueOnce(updatedOffering);

    renderModal({ editOffering: BASE_OFFERING });

    const submitBtn = await screen.findByRole('button', { name: 'Save Changes' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() => expect(mockUpdateOffering).toHaveBeenCalled());
    const payload = mockUpdateOffering.mock.calls[0][1];
    expect(payload).not.toHaveProperty('slug');
  });

  it('sends empty capacity_metadata when max_subscribers is cleared in edit mode', async () => {
    const updatedOffering = { ...BASE_OFFERING };
    mockUpdateOffering.mockResolvedValueOnce(updatedOffering);

    renderModal({ editOffering: BASE_OFFERING });

    // Clear max_subscribers (was 50)
    const maxSubsInput = screen.getByDisplayValue('50');
    fireEvent.change(maxSubsInput, { target: { value: '' } });

    const submitBtn = await screen.findByRole('button', { name: 'Save Changes' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() => expect(mockUpdateOffering).toHaveBeenCalled());
    const payload = mockUpdateOffering.mock.calls[0][1];
    expect(payload.capacity_metadata).toEqual({});
  });

  // ---------------------------------------------------------------------------
  // Error handling
  // ---------------------------------------------------------------------------

  it('shows an error notification when createOffering rejects', async () => {
    mockCreateOffering.mockRejectedValueOnce(new Error('Network error'));

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Network error' }),
      ),
    );
  });

  it('shows a generic error message when rejection is not an Error instance', async () => {
    mockCreateOffering.mockRejectedValueOnce('something went wrong');

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(mockAddNotification).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'error', message: 'Save failed' }),
      ),
    );
  });

  it('re-enables the submit button after a failed submission', async () => {
    mockCreateOffering.mockRejectedValueOnce(new Error('Fail'));

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    // After rejection, button should be re-enabled and no longer say "Saving…"
    await waitFor(() => {
      expect(screen.queryByRole('button', { name: 'Saving…' })).not.toBeInTheDocument();
      expect(screen.getByRole('button', { name: 'Create Offering' })).not.toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // Cancel
  // ---------------------------------------------------------------------------

  it('calls onClose when Cancel is clicked', () => {
    const onClose = jest.fn();
    renderModal({ onClose });

    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onClose).toHaveBeenCalled();
  });

  it('disables Cancel while submitting', async () => {
    // Keep the promise pending so we stay in "Saving…" state
    let resolve: (v: ServiceOffering) => void;
    const pending = new Promise<ServiceOffering>((res) => {
      resolve = res;
    });
    mockCreateOffering.mockReturnValueOnce(pending);

    renderModal();

    fireEvent.change(screen.getByPlaceholderText(/gitea, managed-postgres/i), {
      target: { value: 'my-svc' },
    });
    fireEvent.change(screen.getByPlaceholderText(/Hosted Git, Managed Postgres/i), {
      target: { value: 'My Service' },
    });
    fireEvent.change(screen.getByPlaceholderText(/backend.internal or fd00::1/i), {
      target: { value: 'host.internal' },
    });

    const submitBtn = await screen.findByRole('button', { name: 'Create Offering' });
    await waitFor(() => expect(submitBtn).not.toBeDisabled());
    fireEvent.click(submitBtn);

    await waitFor(() =>
      expect(screen.getByRole('button', { name: 'Saving…' })).toBeInTheDocument(),
    );
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();

    // Resolve to avoid act() warning
    resolve!({ ...BASE_OFFERING });
  });

  // ---------------------------------------------------------------------------
  // Protocol options
  // ---------------------------------------------------------------------------

  it('renders all four protocol options in the select', () => {
    renderModal();
    const select = screen.getByRole('combobox');
    const options = Array.from((select as HTMLSelectElement).options).map((o) => o.value);
    expect(options).toEqual(['https', 'http', 'tls', 'tcp']);
  });

  it('renders all four grant scope buttons', () => {
    renderModal();
    const scopeLabels = ['read', 'write', 'admin', 'migrate'];
    for (const label of scopeLabels) {
      expect(screen.getByRole('button', { name: label })).toBeInTheDocument();
    }
  });
});
