import { FC } from 'react';
import { Sparkles } from 'lucide-react';
import { MultiSelect, type MultiSelectOption } from '@/shared/components/ui/MultiSelect';

// Filter strip for the package browser.
//
// Two operating modes:
//   - browse:   free-text search + structured filters (default)
//   - discover: AI semantic discovery — operator describes a capability
//               need; backend embeds the intent and ranks packages by
//               cosine similarity. Structured filters
//               (architectures, license, kind) apply to both modes.
//
// Architecture/section/license/provides multi-selects + inputs are
// always rendered; the mode toggle only changes the "what to search
// for" row above them.

export type PackageBrowserMode = 'browse' | 'discover';

export interface PackageFilterBarProps {
  // Mode toggle
  mode: PackageBrowserMode;
  onModeChange: (mode: PackageBrowserMode) => void;

  // Browse mode — free-text
  q: string;
  onQChange: (q: string) => void;

  // Discover mode — intent + submit
  intent: string;
  onIntentChange: (intent: string) => void;
  onSubmitIntent: () => void;
  discovering: boolean;

  // Structured filters (apply to both modes)
  architectures: string[];
  onArchitecturesChange: (next: string[]) => void;
  architectureOptions: MultiSelectOption[];

  sections: string[];
  onSectionsChange: (next: string[]) => void;
  sectionOptions: MultiSelectOption[];

  license: string;
  onLicenseChange: (license: string) => void;

  provides: string;
  onProvidesChange: (provides: string) => void;

  disabled?: boolean;
}

export const PackageFilterBar: FC<PackageFilterBarProps> = ({
  mode,
  onModeChange,
  q,
  onQChange,
  intent,
  onIntentChange,
  onSubmitIntent,
  discovering,
  architectures,
  onArchitecturesChange,
  architectureOptions,
  sections,
  onSectionsChange,
  sectionOptions,
  license,
  onLicenseChange,
  provides,
  onProvidesChange,
  disabled = false,
}) => (
  <div className="flex flex-col gap-2">
    {/* Mode toggle */}
    <div
      className="inline-flex rounded border border-theme overflow-hidden self-start"
      role="tablist"
      data-testid="package-filter-mode-toggle"
    >
      <button
        type="button"
        role="tab"
        aria-selected={mode === 'browse'}
        onClick={() => onModeChange('browse')}
        data-testid="package-filter-mode-browse"
        className={
          'px-3 py-1 text-xs ' +
          (mode === 'browse'
            ? 'bg-theme-focus text-white'
            : 'bg-theme-background text-theme-secondary hover:text-theme-primary')
        }
      >
        Browse
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={mode === 'discover'}
        onClick={() => onModeChange('discover')}
        data-testid="package-filter-mode-discover"
        className={
          'px-3 py-1 text-xs flex items-center gap-1 ' +
          (mode === 'discover'
            ? 'bg-theme-focus text-white'
            : 'bg-theme-background text-theme-secondary hover:text-theme-primary')
        }
      >
        <Sparkles size={11} />
        Discover by intent
        <span className="px-1 text-[9px] rounded bg-theme-info/30 text-theme-info">AI</span>
      </button>
    </div>

    {/* Row 1: mode-specific input */}
    {mode === 'browse' ? (
      <input
        type="search"
        value={q}
        onChange={(e) => onQChange(e.target.value)}
        placeholder="Search packages by name or description…"
        disabled={disabled}
        data-testid="package-filter-q"
        className="w-full px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
      />
    ) : (
      <div className="flex flex-col gap-1">
        <div className="flex items-start gap-2">
          <textarea
            value={intent}
            onChange={(e) => onIntentChange(e.target.value)}
            placeholder="Describe what you need — e.g. 'web server with HTTP/2', 'distributed cache', 'mail transport agent with TLS'"
            disabled={disabled || discovering}
            rows={3}
            data-testid="package-discover-intent"
            className="flex-1 px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus resize-y min-h-[4.5rem]"
            onKeyDown={(e) => {
              if (e.key === 'Enter' && (e.ctrlKey || e.metaKey) && intent.trim()) {
                e.preventDefault();
                onSubmitIntent();
              }
            }}
          />
          <button
            type="button"
            onClick={onSubmitIntent}
            disabled={disabled || discovering || !intent.trim()}
            data-testid="package-discover-submit"
            className="px-3 py-1.5 text-xs rounded bg-theme-focus text-white hover:opacity-90 disabled:opacity-50 flex items-center gap-1 self-start"
          >
            <Sparkles size={12} />
            {discovering ? 'Searching…' : 'Find packages'}
          </button>
        </div>
        <div className="text-[10px] text-theme-tertiary">
          Cmd/Ctrl+Enter to submit. Filters below apply to the discovery scope.
        </div>
      </div>
    )}

    {/* Row 2: structured filters — always visible, apply to both modes */}
    <div className="flex flex-wrap items-center gap-2">
      <div className="flex-1 min-w-[12rem]" data-testid="package-filter-architectures-wrap">
        <MultiSelect
          ariaLabel="Architecture filter"
          options={architectureOptions}
          value={architectures}
          onChange={onArchitecturesChange}
          placeholder="Architecture…"
          searchPlaceholder="Search architectures…"
          disabled={disabled}
        />
      </div>
      {mode === 'browse' && (
        <div className="flex-1 min-w-[12rem]" data-testid="package-filter-sections-wrap">
          <MultiSelect
            ariaLabel="Section filter"
            options={sectionOptions}
            value={sections}
            onChange={onSectionsChange}
            placeholder="Section…"
            searchPlaceholder="Search sections…"
            disabled={disabled}
          />
        </div>
      )}
      <input
        type="text"
        value={license}
        onChange={(e) => onLicenseChange(e.target.value)}
        placeholder="License (exact)"
        disabled={disabled}
        data-testid="package-filter-license"
        className="w-40 px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
      />
      {mode === 'browse' && (
        <input
          type="text"
          value={provides}
          onChange={(e) => onProvidesChange(e.target.value)}
          placeholder="Provides (capability)"
          disabled={disabled}
          data-testid="package-filter-provides"
          className="w-44 px-2 py-1 text-sm rounded border border-theme bg-theme-background text-theme-primary placeholder:text-theme-tertiary focus:outline-none focus:border-theme-focus"
        />
      )}
    </div>
  </div>
);

// Common apt sections + rpm groups. UNIONed with sections seen on the
// currently-loaded packages in PackageBrowser, so the dropdown is never
// empty even before the first fetch lands. Lowercase to match server
// stored values (apt) — rpm groups are TitleCase but PostgreSQL section
// filter is case-sensitive so we surface both spellings.
export const DEFAULT_SECTION_OPTIONS: MultiSelectOption[] = [
  { value: 'admin', label: 'admin' },
  { value: 'devel', label: 'devel' },
  { value: 'editors', label: 'editors' },
  { value: 'httpd', label: 'httpd' },
  { value: 'kernel', label: 'kernel' },
  { value: 'libs', label: 'libs' },
  { value: 'mail', label: 'mail' },
  { value: 'net', label: 'net' },
  { value: 'python', label: 'python' },
  { value: 'sound', label: 'sound' },
  { value: 'text', label: 'text' },
  { value: 'utils', label: 'utils' },
  { value: 'web', label: 'web' },
  { value: 'x11', label: 'x11' },
];
