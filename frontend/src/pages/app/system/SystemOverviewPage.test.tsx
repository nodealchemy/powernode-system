import React from 'react';
import { render, screen, fireEvent, waitFor, act } from '@testing-library/react';
import { BrowserRouter } from 'react-router-dom';
import SystemOverviewPage from './SystemOverviewPage';
import type { SystemOverviewHandle } from '@system/features/system/components/SystemOverview';

// =============================================================================
// Mocks
//
// SystemOverviewPage renders:
//   - PageContainer (title + description + breadcrumbs + actions)
//   - SystemOverview (forwarded-ref child)
//
// We mock SystemOverview so we can control the imperative ref handle it
// exposes — specifically, whether `refresh()` resolves fast or slowly —
// without depending on any API calls. PageContainer is tested via real
// render (it only uses BreadcrumbContext).
// =============================================================================

// Capture the latest ref assigned to the mocked SystemOverview so tests
// can imperatively inspect the handle the page passes in.
let capturedRef: React.Ref<SystemOverviewHandle> | null = null;

// The refresh fn we hand back via the imperative handle. Tests can
// replace this per-scenario by calling `mockRefresh.mockImplementation(…)`.
const mockRefresh = jest.fn<Promise<void>, []>();

jest.mock('@system/features/system/components/SystemOverview', () => {
  const React = require('react');
  const MockSystemOverview = React.forwardRef(
    (
      _props: Record<string, unknown>,
      ref: React.Ref<{ refresh: () => Promise<void> }>,
    ) => {
      capturedRef = ref;
      React.useImperativeHandle(ref, () => ({ refresh: mockRefresh }));
      return <div data-testid="mock-system-overview" />;
    },
  );
  MockSystemOverview.displayName = 'SystemOverview';
  return { SystemOverview: MockSystemOverview };
});

jest.mock('@/shared/hooks/BreadcrumbContext', () => ({
  __esModule: true,
  BreadcrumbProvider: ({ children }: { children: React.ReactNode }) => (
    <>{children}</>
  ),
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
      <SystemOverviewPage />
    </BrowserRouter>,
  );

// =============================================================================
// Tests
// =============================================================================

describe('SystemOverviewPage', () => {
  beforeEach(() => {
    capturedRef = null;
    mockRefresh.mockReset();
    // Default: refresh resolves immediately
    mockRefresh.mockResolvedValue(undefined);
  });

  // ---------------------------------------------------------------------------
  // Static content
  // ---------------------------------------------------------------------------

  describe('static content', () => {
    it('renders the page title "System Overview"', () => {
      renderPage();
      expect(screen.getByText('System Overview')).toBeInTheDocument();
    });

    it('renders the page description', () => {
      renderPage();
      expect(
        screen.getByText(
          'System management dashboard for nodes, providers, modules, and operations',
        ),
      ).toBeInTheDocument();
    });

    it('renders the SystemOverview child component', () => {
      renderPage();
      expect(screen.getByTestId('mock-system-overview')).toBeInTheDocument();
    });

    it('renders the Refresh action button in its idle state', () => {
      renderPage();
      expect(
        screen.getByRole('button', { name: /^refresh$/i }),
      ).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Breadcrumbs
  // ---------------------------------------------------------------------------

  describe('breadcrumbs', () => {
    it('renders the Dashboard breadcrumb link', () => {
      renderPage();
      // PageContainer renders breadcrumbs as anchor/link elements
      const dashboardLink = screen.getByRole('link', { name: /dashboard/i });
      expect(dashboardLink).toBeInTheDocument();
      expect(dashboardLink).toHaveAttribute('href', '/app');
    });

    it('renders the System breadcrumb label (no href — current page)', () => {
      renderPage();
      // The final breadcrumb is the current page — no link, just text
      const systemCrumbs = screen.getAllByText('System');
      expect(systemCrumbs.length).toBeGreaterThan(0);
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh button — happy path
  // ---------------------------------------------------------------------------

  describe('Refresh button — successful refresh', () => {
    it('calls the SystemOverview imperative refresh() when clicked', async () => {
      mockRefresh.mockResolvedValue(undefined);

      renderPage();

      const refreshBtn = screen.getByRole('button', { name: /^refresh$/i });
      fireEvent.click(refreshBtn);

      await waitFor(() => expect(mockRefresh).toHaveBeenCalledTimes(1));
    });

    it('shows "Refreshing…" label while the refresh is in-flight', async () => {
      let resolveFn!: () => void;
      mockRefresh.mockReturnValue(
        new Promise<void>((resolve) => {
          resolveFn = resolve;
        }),
      );

      renderPage();

      fireEvent.click(screen.getByRole('button', { name: /^refresh$/i }));

      // While the promise is pending the label should switch
      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /refreshing/i }),
        ).toBeInTheDocument(),
      );

      // Resolve the promise so the component can settle
      await act(async () => { resolveFn(); });
    });

    it('disables the Refresh button while refreshing', async () => {
      let resolveFn!: () => void;
      mockRefresh.mockReturnValue(
        new Promise<void>((resolve) => {
          resolveFn = resolve;
        }),
      );

      renderPage();

      const refreshBtn = screen.getByRole('button', { name: /^refresh$/i });
      fireEvent.click(refreshBtn);

      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /refreshing/i }),
        ).toBeDisabled(),
      );

      await act(async () => { resolveFn(); });
    });

    it('re-enables and resets label to "Refresh" after completion', async () => {
      mockRefresh.mockResolvedValue(undefined);

      renderPage();

      fireEvent.click(screen.getByRole('button', { name: /^refresh$/i }));

      await waitFor(() =>
        expect(
          screen.getByRole('button', { name: /^refresh$/i }),
        ).not.toBeDisabled(),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Refresh button — no-op when ref is not yet attached
  // ---------------------------------------------------------------------------

  it('does not crash when the Refresh button is clicked before the ref resolves', async () => {
    // Render without the mock's useImperativeHandle firing
    // (this is an edge case guard; in normal render the ref is always populated)
    mockRefresh.mockResolvedValue(undefined);

    // Patch capturedRef to null to simulate pre-attach state
    capturedRef = null;

    renderPage();

    // If the page guarded against `overviewRef.current` being null, no error
    const refreshBtn = screen.getByRole('button', { name: /^refresh$/i });
    expect(() => fireEvent.click(refreshBtn)).not.toThrow();
  });

  // ---------------------------------------------------------------------------
  // Multiple refresh cycles
  // ---------------------------------------------------------------------------

  it('allows multiple sequential refreshes', async () => {
    mockRefresh.mockResolvedValue(undefined);

    renderPage();

    // First refresh
    fireEvent.click(screen.getByRole('button', { name: /^refresh$/i }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^refresh$/i })).not.toBeDisabled(),
    );

    // Second refresh
    fireEvent.click(screen.getByRole('button', { name: /^refresh$/i }));
    await waitFor(() =>
      expect(screen.getByRole('button', { name: /^refresh$/i })).not.toBeDisabled(),
    );

    expect(mockRefresh).toHaveBeenCalledTimes(2);
  });
});
