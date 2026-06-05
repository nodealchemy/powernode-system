import React from 'react';
import { render, screen } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import TemplateComposerPageWrapper from './TemplateComposerPage';

// =============================================================================
// Mocks
// =============================================================================

// Mock the heavy inner component so this test stays focused on the page-wrapper's
// own responsibilities: permission gating and PageContainer title.
jest.mock(
  '@system/features/system/components/templates/composer/TemplateComposerPage',
  () => ({
    TemplateComposerPage: () => (
      <div data-testid="template-composer-inner">TemplateComposerInner</div>
    ),
  }),
);

let mockHasPermission = true;
jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: () => mockHasPermission,
  }),
}));

jest.mock('@/shared/hooks/useNotifications', () => ({
  useNotifications: () => ({
    addNotification: jest.fn(),
    showNotification: jest.fn(),
  }),
}));

jest.mock('@/shared/hooks/BreadcrumbContext', () => ({
  __esModule: true,
  BreadcrumbProvider: ({ children }: { children: React.ReactNode }) => <>{children}</>,
  useBreadcrumb: () => ({
    breadcrumbs: [],
    setBreadcrumbs: jest.fn(),
    getCurrentBreadcrumbs: () => [],
    setCurrentPage: jest.fn(),
  }),
}));

// =============================================================================
// Helpers
// =============================================================================

const renderPage = () =>
  render(
    <BrowserRouter>
      <TemplateComposerPageWrapper />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('TemplateComposerPage (page-level wrapper)', () => {
  beforeEach(() => {
    mockHasPermission = true;
  });

  // ---------------------------------------------------------------------------
  // Render with permission
  // ---------------------------------------------------------------------------

  it('renders the PageContainer with title "Template Composer"', () => {
    renderPage();
    expect(
      screen.getByRole('heading', { name: 'Template Composer' }),
    ).toBeInTheDocument();
  });

  it('renders the inner TemplateComposerComponent when the user has the required permission', () => {
    renderPage();
    expect(screen.getByTestId('template-composer-inner')).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Permission gating — no permission
  // ---------------------------------------------------------------------------

  it('does NOT render the inner component when permission is missing', () => {
    mockHasPermission = false;
    renderPage();
    expect(screen.queryByTestId('template-composer-inner')).not.toBeInTheDocument();
  });

  it('shows the permission-denied message when the user lacks system.templates.update', () => {
    mockHasPermission = false;
    renderPage();
    // The message text and the <code> tag are sibling nodes in one <div>, so
    // the full string is split across elements. Match the outer div by regex.
    expect(
      screen.getByText(/You don't have permission to compose templates/),
    ).toBeInTheDocument();
  });

  it('mentions the required permission code in the denied message', () => {
    mockHasPermission = false;
    renderPage();
    expect(screen.getByText('system.templates.update')).toBeInTheDocument();
  });

  it('still renders a PageContainer with title "Template Composer" when permission is missing', () => {
    mockHasPermission = false;
    renderPage();
    expect(
      screen.getByRole('heading', { name: 'Template Composer' }),
    ).toBeInTheDocument();
  });

  // ---------------------------------------------------------------------------
  // Named export parity
  // ---------------------------------------------------------------------------

  it('exports the wrapper as the named TemplateComposerPage too', async () => {
    const mod = await import('./TemplateComposerPage');
    expect(typeof mod.TemplateComposerPage).toBe('function');
  });
});
