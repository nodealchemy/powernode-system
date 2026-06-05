import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import {
  PackageFilterBar,
  type PackageBrowserMode,
  type PackageFilterBarProps,
  DEFAULT_SECTION_OPTIONS,
} from './PackageFilterBar';

// =============================================================================
// Mocks
//
// PackageFilterBar imports only:
//   - lucide-react (Sparkles icon) — no mock needed, renders fine in jsdom
//   - @/shared/components/ui/MultiSelect — use the real component; it is a
//     pure UI component with no API calls and renders correctly in jsdom.
//
// No apiClient, no hooks, no router — none needed here.
// =============================================================================

// =============================================================================
// Fixtures
// =============================================================================

const ARCH_OPTIONS = [
  { value: 'amd64', label: 'amd64' },
  { value: 'arm64', label: 'arm64' },
  { value: 'armhf', label: 'armhf' },
];

const SECTION_OPTIONS = [
  { value: 'utils', label: 'utils' },
  { value: 'libs', label: 'libs' },
  { value: 'devel', label: 'devel' },
];

/** Build a complete set of props with sensible defaults. Callers may spread-override. */
function makeProps(overrides: Partial<PackageFilterBarProps> = {}): PackageFilterBarProps {
  return {
    mode: 'browse',
    onModeChange: jest.fn(),
    q: '',
    onQChange: jest.fn(),
    intent: '',
    onIntentChange: jest.fn(),
    onSubmitIntent: jest.fn(),
    discovering: false,
    architectures: [],
    onArchitecturesChange: jest.fn(),
    architectureOptions: ARCH_OPTIONS,
    sections: [],
    onSectionsChange: jest.fn(),
    sectionOptions: SECTION_OPTIONS,
    license: '',
    onLicenseChange: jest.fn(),
    provides: '',
    onProvidesChange: jest.fn(),
    disabled: false,
    ...overrides,
  };
}

// =============================================================================
// Tests
// =============================================================================

describe('PackageFilterBar', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  // ---------------------------------------------------------------------------
  // Render — browse mode (default)
  // ---------------------------------------------------------------------------

  describe('render — browse mode', () => {
    it('renders the mode toggle buttons', () => {
      render(<PackageFilterBar {...makeProps()} />);

      expect(screen.getByTestId('package-filter-mode-browse')).toBeInTheDocument();
      expect(screen.getByTestId('package-filter-mode-discover')).toBeInTheDocument();
    });

    it('marks the Browse tab as selected when mode=browse', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'browse' })} />);

      const browseTab = screen.getByTestId('package-filter-mode-browse');
      const discoverTab = screen.getByTestId('package-filter-mode-discover');

      expect(browseTab).toHaveAttribute('aria-selected', 'true');
      expect(discoverTab).toHaveAttribute('aria-selected', 'false');
    });

    it('renders the free-text search input in browse mode', () => {
      render(<PackageFilterBar {...makeProps({ q: 'nginx' })} />);

      const input = screen.getByTestId('package-filter-q');
      expect(input).toBeInTheDocument();
      expect(input).toHaveValue('nginx');
    });

    it('does NOT render the intent textarea in browse mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'browse' })} />);

      expect(screen.queryByTestId('package-discover-intent')).not.toBeInTheDocument();
    });

    it('renders the architecture multi-select wrapper', () => {
      render(<PackageFilterBar {...makeProps()} />);
      expect(screen.getByTestId('package-filter-architectures-wrap')).toBeInTheDocument();
    });

    it('renders the section multi-select wrapper in browse mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'browse' })} />);
      expect(screen.getByTestId('package-filter-sections-wrap')).toBeInTheDocument();
    });

    it('renders the license input in browse mode', () => {
      render(<PackageFilterBar {...makeProps({ license: 'MIT' })} />);

      const input = screen.getByTestId('package-filter-license');
      expect(input).toBeInTheDocument();
      expect(input).toHaveValue('MIT');
    });

    it('renders the provides input in browse mode', () => {
      render(<PackageFilterBar {...makeProps({ provides: 'httpd' })} />);

      const input = screen.getByTestId('package-filter-provides');
      expect(input).toBeInTheDocument();
      expect(input).toHaveValue('httpd');
    });
  });

  // ---------------------------------------------------------------------------
  // Render — discover mode
  // ---------------------------------------------------------------------------

  describe('render — discover mode', () => {
    it('marks the Discover tab as selected when mode=discover', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);

      const browseTab = screen.getByTestId('package-filter-mode-browse');
      const discoverTab = screen.getByTestId('package-filter-mode-discover');

      expect(discoverTab).toHaveAttribute('aria-selected', 'true');
      expect(browseTab).toHaveAttribute('aria-selected', 'false');
    });

    it('renders the intent textarea in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover', intent: 'web server' })} />);

      const textarea = screen.getByTestId('package-discover-intent');
      expect(textarea).toBeInTheDocument();
      expect(textarea).toHaveValue('web server');
    });

    it('renders the Find packages submit button in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);

      expect(screen.getByTestId('package-discover-submit')).toBeInTheDocument();
    });

    it('labels the button "Find packages" when not discovering', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover', discovering: false })} />);
      expect(screen.getByTestId('package-discover-submit')).toHaveTextContent('Find packages');
    });

    it('labels the button "Searching…" while discovering', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover', discovering: true, intent: 'cache' })} />);
      expect(screen.getByTestId('package-discover-submit')).toHaveTextContent('Searching…');
    });

    it('does NOT render the free-text search input in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
      expect(screen.queryByTestId('package-filter-q')).not.toBeInTheDocument();
    });

    it('does NOT render the section filter in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
      expect(screen.queryByTestId('package-filter-sections-wrap')).not.toBeInTheDocument();
    });

    it('does NOT render the provides input in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
      expect(screen.queryByTestId('package-filter-provides')).not.toBeInTheDocument();
    });

    it('still renders the architecture filter and license input in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
      expect(screen.getByTestId('package-filter-architectures-wrap')).toBeInTheDocument();
      expect(screen.getByTestId('package-filter-license')).toBeInTheDocument();
    });

    it('shows the Cmd/Ctrl+Enter hint text', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
      expect(
        screen.getByText(/Cmd\/Ctrl\+Enter to submit/i),
      ).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Interactions — mode toggle
  // ---------------------------------------------------------------------------

  describe('mode toggle interactions', () => {
    it('calls onModeChange("discover") when the Discover tab is clicked', () => {
      const onModeChange = jest.fn();
      render(<PackageFilterBar {...makeProps({ mode: 'browse', onModeChange })} />);

      fireEvent.click(screen.getByTestId('package-filter-mode-discover'));

      expect(onModeChange).toHaveBeenCalledTimes(1);
      expect(onModeChange).toHaveBeenCalledWith('discover');
    });

    it('calls onModeChange("browse") when the Browse tab is clicked', () => {
      const onModeChange = jest.fn();
      render(<PackageFilterBar {...makeProps({ mode: 'discover', onModeChange })} />);

      fireEvent.click(screen.getByTestId('package-filter-mode-browse'));

      expect(onModeChange).toHaveBeenCalledTimes(1);
      expect(onModeChange).toHaveBeenCalledWith('browse');
    });
  });

  // ---------------------------------------------------------------------------
  // Interactions — browse mode inputs
  // ---------------------------------------------------------------------------

  describe('browse mode input interactions', () => {
    it('calls onQChange with the new value when the search input changes', () => {
      const onQChange = jest.fn();
      render(<PackageFilterBar {...makeProps({ onQChange })} />);

      fireEvent.change(screen.getByTestId('package-filter-q'), {
        target: { value: 'curl' },
      });

      expect(onQChange).toHaveBeenCalledWith('curl');
    });

    it('calls onLicenseChange when the license input changes', () => {
      const onLicenseChange = jest.fn();
      render(<PackageFilterBar {...makeProps({ onLicenseChange })} />);

      fireEvent.change(screen.getByTestId('package-filter-license'), {
        target: { value: 'Apache-2.0' },
      });

      expect(onLicenseChange).toHaveBeenCalledWith('Apache-2.0');
    });

    it('calls onProvidesChange when the provides input changes', () => {
      const onProvidesChange = jest.fn();
      render(<PackageFilterBar {...makeProps({ onProvidesChange })} />);

      fireEvent.change(screen.getByTestId('package-filter-provides'), {
        target: { value: 'smtp-server' },
      });

      expect(onProvidesChange).toHaveBeenCalledWith('smtp-server');
    });
  });

  // ---------------------------------------------------------------------------
  // Interactions — discover mode
  // ---------------------------------------------------------------------------

  describe('discover mode input interactions', () => {
    it('calls onIntentChange when the intent textarea changes', () => {
      const onIntentChange = jest.fn();
      render(<PackageFilterBar {...makeProps({ mode: 'discover', onIntentChange })} />);

      fireEvent.change(screen.getByTestId('package-discover-intent'), {
        target: { value: 'distributed cache' },
      });

      expect(onIntentChange).toHaveBeenCalledWith('distributed cache');
    });

    it('calls onSubmitIntent when the Find packages button is clicked', () => {
      const onSubmitIntent = jest.fn();
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'smtp', onSubmitIntent })}
        />,
      );

      fireEvent.click(screen.getByTestId('package-discover-submit'));

      expect(onSubmitIntent).toHaveBeenCalledTimes(1);
    });

    it('calls onSubmitIntent on Ctrl+Enter when intent is non-empty', () => {
      const onSubmitIntent = jest.fn();
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'web server', onSubmitIntent })}
        />,
      );

      fireEvent.keyDown(screen.getByTestId('package-discover-intent'), {
        key: 'Enter',
        ctrlKey: true,
      });

      expect(onSubmitIntent).toHaveBeenCalledTimes(1);
    });

    it('calls onSubmitIntent on Meta+Enter when intent is non-empty', () => {
      const onSubmitIntent = jest.fn();
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'mail agent', onSubmitIntent })}
        />,
      );

      fireEvent.keyDown(screen.getByTestId('package-discover-intent'), {
        key: 'Enter',
        metaKey: true,
      });

      expect(onSubmitIntent).toHaveBeenCalledTimes(1);
    });

    it('does NOT call onSubmitIntent on Ctrl+Enter when intent is blank', () => {
      const onSubmitIntent = jest.fn();
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: '   ', onSubmitIntent })}
        />,
      );

      fireEvent.keyDown(screen.getByTestId('package-discover-intent'), {
        key: 'Enter',
        ctrlKey: true,
      });

      expect(onSubmitIntent).not.toHaveBeenCalled();
    });

    it('does NOT call onSubmitIntent on plain Enter (no modifier)', () => {
      const onSubmitIntent = jest.fn();
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'ftp daemon', onSubmitIntent })}
        />,
      );

      fireEvent.keyDown(screen.getByTestId('package-discover-intent'), {
        key: 'Enter',
        ctrlKey: false,
        metaKey: false,
      });

      expect(onSubmitIntent).not.toHaveBeenCalled();
    });
  });

  // ---------------------------------------------------------------------------
  // Disabled state
  // ---------------------------------------------------------------------------

  describe('disabled state', () => {
    it('disables the free-text search input when disabled=true', () => {
      render(<PackageFilterBar {...makeProps({ disabled: true })} />);
      expect(screen.getByTestId('package-filter-q')).toBeDisabled();
    });

    it('disables the license input when disabled=true', () => {
      render(<PackageFilterBar {...makeProps({ disabled: true })} />);
      expect(screen.getByTestId('package-filter-license')).toBeDisabled();
    });

    it('disables the provides input when disabled=true', () => {
      render(<PackageFilterBar {...makeProps({ disabled: true })} />);
      expect(screen.getByTestId('package-filter-provides')).toBeDisabled();
    });

    it('disables the intent textarea when disabled=true in discover mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'discover', disabled: true })} />);
      expect(screen.getByTestId('package-discover-intent')).toBeDisabled();
    });

    it('disables the submit button when disabled=true', () => {
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'something', disabled: true })}
        />,
      );
      expect(screen.getByTestId('package-discover-submit')).toBeDisabled();
    });

    it('disables the submit button when discovering=true', () => {
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'something', discovering: true })}
        />,
      );
      expect(screen.getByTestId('package-discover-submit')).toBeDisabled();
    });

    it('disables the submit button when intent is empty (whitespace only)', () => {
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: '   ', discovering: false })}
        />,
      );
      expect(screen.getByTestId('package-discover-submit')).toBeDisabled();
    });

    it('enables the submit button when intent is non-empty and not discovering', () => {
      render(
        <PackageFilterBar
          {...makeProps({ mode: 'discover', intent: 'smtp daemon', discovering: false, disabled: false })}
        />,
      );
      expect(screen.getByTestId('package-discover-submit')).not.toBeDisabled();
    });
  });

  // ---------------------------------------------------------------------------
  // DEFAULT_SECTION_OPTIONS export
  // ---------------------------------------------------------------------------

  describe('DEFAULT_SECTION_OPTIONS', () => {
    it('exports DEFAULT_SECTION_OPTIONS with the expected core sections', () => {
      const values = DEFAULT_SECTION_OPTIONS.map((o) => o.value);
      expect(values).toContain('admin');
      expect(values).toContain('devel');
      expect(values).toContain('libs');
      expect(values).toContain('utils');
      expect(values).toContain('web');
      expect(values).toContain('net');
    });

    it('has matching label and value for every entry', () => {
      DEFAULT_SECTION_OPTIONS.forEach((opt) => {
        expect(opt.label).toBe(opt.value);
      });
    });

    it('contains exactly 14 entries', () => {
      expect(DEFAULT_SECTION_OPTIONS).toHaveLength(14);
    });
  });

  // ---------------------------------------------------------------------------
  // Tab role / ARIA
  // ---------------------------------------------------------------------------

  describe('accessibility / ARIA', () => {
    it('renders the mode toggle with role="tablist"', () => {
      render(<PackageFilterBar {...makeProps()} />);
      expect(screen.getByTestId('package-filter-mode-toggle')).toHaveAttribute(
        'role',
        'tablist',
      );
    });

    it('each mode button has role="tab"', () => {
      render(<PackageFilterBar {...makeProps()} />);
      const tabs = screen.getAllByRole('tab');
      expect(tabs).toHaveLength(2);
    });

    it('architecture multi-select has an aria-label', () => {
      render(<PackageFilterBar {...makeProps()} />);
      // MultiSelect renders a div[role="combobox"] with aria-label
      expect(
        screen.getByRole('combobox', { name: /architecture filter/i }),
      ).toBeInTheDocument();
    });

    it('section multi-select has an aria-label in browse mode', () => {
      render(<PackageFilterBar {...makeProps({ mode: 'browse' })} />);
      expect(
        screen.getByRole('combobox', { name: /section filter/i }),
      ).toBeInTheDocument();
    });
  });

  // ---------------------------------------------------------------------------
  // Mode-specific conditional filters (cross-check)
  // ---------------------------------------------------------------------------

  describe('conditional filter visibility', () => {
    const browseModeFilters = [
      { testId: 'package-filter-q', label: 'free-text search input' },
      { testId: 'package-filter-sections-wrap', label: 'section filter' },
      { testId: 'package-filter-provides', label: 'provides filter' },
    ];

    browseModeFilters.forEach(({ testId, label }) => {
      it(`shows ${label} only in browse mode`, () => {
        const { rerender } = render(<PackageFilterBar {...makeProps({ mode: 'browse' })} />);
        expect(screen.getByTestId(testId)).toBeInTheDocument();

        rerender(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
        expect(screen.queryByTestId(testId)).not.toBeInTheDocument();
      });
    });

    it('shows the intent textarea only in discover mode', () => {
      const { rerender } = render(
        <PackageFilterBar {...makeProps({ mode: 'browse' })} />,
      );
      expect(screen.queryByTestId('package-discover-intent')).not.toBeInTheDocument();

      rerender(<PackageFilterBar {...makeProps({ mode: 'discover' })} />);
      expect(screen.getByTestId('package-discover-intent')).toBeInTheDocument();
    });

    it('always renders the architecture filter regardless of mode', () => {
      const modes: PackageBrowserMode[] = ['browse', 'discover'];
      modes.forEach((mode) => {
        const { unmount } = render(<PackageFilterBar {...makeProps({ mode })} />);
        expect(screen.getByTestId('package-filter-architectures-wrap')).toBeInTheDocument();
        unmount();
      });
    });

    it('always renders the license input regardless of mode', () => {
      const modes: PackageBrowserMode[] = ['browse', 'discover'];
      modes.forEach((mode) => {
        const { unmount } = render(<PackageFilterBar {...makeProps({ mode })} />);
        expect(screen.getByTestId('package-filter-license')).toBeInTheDocument();
        unmount();
      });
    });
  });
});
