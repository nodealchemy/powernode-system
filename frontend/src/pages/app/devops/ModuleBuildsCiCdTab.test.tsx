import React from 'react';
import { render, screen, waitFor } from '@testing-library/react';
import { ModuleBuildsCiCdTab } from './ModuleBuildsCiCdTab';

// =============================================================================
// Permission mock — mutated per-test so we can exercise the read gate.
// =============================================================================

let mockHasPermission = (_permission: string): boolean => true;

jest.mock('@/shared/hooks/usePermissions', () => ({
  usePermissions: () => ({
    hasPermission: (permission: string) => mockHasPermission(permission),
  }),
}));

// =============================================================================
// Stub ModuleBuildsTab — its own internals are covered by
// ModuleBuildsTab.test.tsx; here we only need to confirm this adapter wires
// permission gating and bridges ModuleBuildsTab's handle-shaped
// onActionsReady into the PageAction-array shape CiCdPage's other tabs use.
// =============================================================================

jest.mock('@system/features/system/components/operations/ModuleBuildsTab', () => {
  // jest.mock factories can't close over out-of-scope variables (including a
  // top-level `React` import) — require it locally instead.
  const ReactLocal = require('react');
  return {
    ModuleBuildsTab: ({ onActionsReady }: { onActionsReady?: (h: { refresh: () => void } | null) => void }) => {
      ReactLocal.useEffect(() => {
        onActionsReady?.({ refresh: jest.fn() });
        return () => onActionsReady?.(null);
      }, [onActionsReady]);
      return ReactLocal.createElement('div', { 'data-testid': 'module-builds-tab' }, 'Module Builds Tab');
    },
  };
});

// =============================================================================
// Tests
// =============================================================================

describe('ModuleBuildsCiCdTab', () => {
  beforeEach(() => {
    mockHasPermission = () => true;
  });

  it('renders the ModuleBuildsTab when the operator can read module builds', async () => {
    render(<ModuleBuildsCiCdTab />);

    await waitFor(() => expect(screen.getByTestId('module-builds-tab')).toBeInTheDocument());
  });

  it('shows a permission-denied message instead of the tab when read is not granted', () => {
    mockHasPermission = (permission) => permission !== 'system.module_builds.read';

    render(<ModuleBuildsCiCdTab />);

    expect(screen.getByText(/don.t have permission to view module build batches/i)).toBeInTheDocument();
    expect(screen.queryByTestId('module-builds-tab')).not.toBeInTheDocument();
  });

  it('bridges the handle-shaped onActionsReady into a Refresh PageAction', async () => {
    const onActionsReady = jest.fn();

    render(<ModuleBuildsCiCdTab onActionsReady={onActionsReady} />);

    await waitFor(() =>
      expect(onActionsReady).toHaveBeenCalledWith([
        expect.objectContaining({ label: 'Refresh', onClick: expect.any(Function) }),
      ]),
    );
  });

  it('clears the page actions when the tab unmounts', async () => {
    const onActionsReady = jest.fn();

    const { unmount } = render(<ModuleBuildsCiCdTab onActionsReady={onActionsReady} />);

    await waitFor(() => expect(onActionsReady).toHaveBeenCalledWith(expect.any(Array)));
    onActionsReady.mockClear();

    unmount();

    expect(onActionsReady).toHaveBeenCalledWith([]);
  });
});
