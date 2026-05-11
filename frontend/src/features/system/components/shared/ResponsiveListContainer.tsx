import React, { Children, isValidElement } from 'react';
import type { LucideIcon } from 'lucide-react';
import { Plus, RefreshCw } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { InfiniteScrollSentinel } from './InfiniteScrollSentinel';

// ResponsiveListContainer — compound component that absorbs the standard
// list-page chrome that 11 list components in the System extension were
// duplicating: initial-load spinner, "no items" empty-state, filter row
// with refresh button, count summary, and the desktop-table /
// mobile-cards split.
//
// Slots are children of named subcomponents — `ResponsiveListContainer.Filters`,
// `ResponsiveListContainer.Desktop`, `ResponsiveListContainer.Mobile`.
// The top-level container picks them up by component identity and renders
// each in the right place.

export interface EmptyStateProps {
  /** Lucide icon component to render in the centered icon slot. */
  icon: LucideIcon;
  /** Heading text. */
  title: string;
  /** Body text below the heading. */
  description?: string;
  /** Optional primary CTA shown in the empty state (e.g., "Create"). */
  action?: {
    label: string;
    onClick: () => void;
    permission?: boolean; // suppresses the button when false (e.g., user lacks the create permission)
  };
}

export interface ResponsiveListContainerProps {
  /** Whether the initial load is in flight (no items shown yet). */
  loading: boolean;
  /** Whether a refresh is in flight (button shows spinner, list stays). */
  refreshing?: boolean;
  /** Total number of items currently held (pre-filter). */
  totalCount: number;
  /** Number of items after filters are applied. Used for the "showing N of M" hint. */
  filteredCount: number;
  /** Empty-state when no items are loaded at all. */
  emptyState: EmptyStateProps;
  /** Called when the refresh button is pressed. */
  onRefresh?: () => void;

  // ---- Infinite scroll (optional) ----
  // Provide these together to enable the intersection-observer sentinel
  // and the loading-more / end-of-list indicators that follow the
  // platform's existing infinite-scroll convention (see
  // frontend/src/features/ai/memory/pages/MemoryExplorerPage.tsx).

  /** Called when the sentinel enters the viewport. Enables infinite scroll. */
  onLoadMore?: () => void;
  /** Whether more pages exist on the server. */
  hasMore?: boolean;
  /** Whether the next page is currently loading. */
  loadingMore?: boolean;
  /** Server-reported total count for the "All N loaded" marker. */
  serverTotalCount?: number;

  /** Optional extra wrapper class. */
  className?: string;
  /** Slot children: <Filters>, <Desktop>, <Mobile>. */
  children: React.ReactNode;
}

interface SlotProps {
  children: React.ReactNode;
}

// Slot subcomponents — identity-checked by the parent.
const Filters: React.FC<SlotProps> = ({ children }) => <>{children}</>;
Filters.displayName = 'ResponsiveListContainer.Filters';

const Desktop: React.FC<SlotProps> = ({ children }) => <>{children}</>;
Desktop.displayName = 'ResponsiveListContainer.Desktop';

const Mobile: React.FC<SlotProps> = ({ children }) => <>{children}</>;
Mobile.displayName = 'ResponsiveListContainer.Mobile';

// `Body` is the fallback slot for layouts that don't need a desktop-table /
// mobile-cards split — e.g., grid-of-cards lists like ProviderList. When
// provided, it replaces the Desktop/Mobile slots and is rendered without
// the surface card wrapper (since the items inside typically own their
// own surfaces).
const Body: React.FC<SlotProps> = ({ children }) => <>{children}</>;
Body.displayName = 'ResponsiveListContainer.Body';

function findSlot(
  children: React.ReactNode,
  Slot: React.FC<SlotProps>
): React.ReactNode | null {
  let found: React.ReactNode | null = null;
  Children.forEach(children, (child) => {
    if (isValidElement(child) && child.type === Slot) {
      found = child;
    }
  });
  return found;
}

interface ResponsiveListContainerComponent extends React.FC<ResponsiveListContainerProps> {
  Filters: typeof Filters;
  Desktop: typeof Desktop;
  Mobile: typeof Mobile;
  Body: typeof Body;
}

const ResponsiveListContainerImpl: React.FC<ResponsiveListContainerProps> = ({
  loading,
  refreshing = false,
  totalCount,
  filteredCount,
  emptyState,
  onRefresh,
  onLoadMore,
  hasMore,
  loadingMore = false,
  serverTotalCount,
  className = '',
  children,
}) => {
  const infiniteEnabled = onLoadMore !== undefined;
  const filtersSlot = findSlot(children, Filters);
  const desktopSlot = findSlot(children, Desktop);
  const mobileSlot = findSlot(children, Mobile);
  const bodySlot = findSlot(children, Body);

  // Initial load — no items yet.
  if (loading && totalCount === 0) {
    return (
      <div className={`bg-theme-surface rounded-lg border border-theme p-8 ${className}`}>
        <div className="flex items-center justify-center">
          <LoadingSpinner size="lg" />
        </div>
      </div>
    );
  }

  // Loaded but empty.
  if (!loading && totalCount === 0) {
    const Icon = emptyState.icon;
    return (
      <div className={`bg-theme-surface rounded-lg border border-theme p-8 text-center ${className}`}>
        <Icon className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
        <h3 className="text-lg font-medium text-theme-primary mb-2">{emptyState.title}</h3>
        {emptyState.description && (
          <p className="text-theme-secondary mb-4">{emptyState.description}</p>
        )}
        {emptyState.action && emptyState.action.permission !== false && (
          <Button variant="primary" onClick={emptyState.action.onClick}>
            <Plus className="w-4 h-4 mr-2" />
            {emptyState.action.label}
          </Button>
        )}
      </div>
    );
  }

  return (
    <div className={`space-y-6 ${className}`}>
      {(filtersSlot || onRefresh) && (
        <div className="bg-theme-surface rounded-lg border border-theme p-4">
          <div className="flex flex-col sm:flex-row gap-4">
            {filtersSlot && <div className="flex-1 flex flex-col sm:flex-row gap-4">{filtersSlot}</div>}
            {onRefresh && (
              <Button
                variant="outline"
                onClick={onRefresh}
                disabled={refreshing}
                className="sm:w-auto"
                title="Refresh"
              >
                <RefreshCw className={`w-4 h-4 ${refreshing ? 'animate-spin' : ''}`} />
              </Button>
            )}
          </div>

          {filteredCount < totalCount && (
            <div className="mt-4 text-sm text-theme-secondary">
              Showing {filteredCount} of {totalCount}
            </div>
          )}
        </div>
      )}

      {bodySlot ? (
        bodySlot
      ) : (
        <div className="bg-theme-surface rounded-lg border border-theme overflow-hidden">
          {desktopSlot && <div className="hidden md:block">{desktopSlot}</div>}
          {mobileSlot && <div className="md:hidden divide-y divide-theme">{mobileSlot}</div>}
        </div>
      )}

      {infiniteEnabled && (
        <>
          <InfiniteScrollSentinel
            onIntersect={onLoadMore!}
            enabled={!!hasMore && !loadingMore && !loading}
          />
          {loadingMore && (
            <div className="flex justify-center py-4">
              <LoadingSpinner size="sm" />
            </div>
          )}
          {!hasMore && totalCount > 0 && serverTotalCount !== undefined && (
            <p className="text-center text-sm text-theme-tertiary py-2">
              All {serverTotalCount} loaded
            </p>
          )}
        </>
      )}
    </div>
  );
};

// Attach the slot subcomponents.
const ResponsiveListContainer = ResponsiveListContainerImpl as ResponsiveListContainerComponent;
ResponsiveListContainer.Filters = Filters;
ResponsiveListContainer.Desktop = Desktop;
ResponsiveListContainer.Mobile = Mobile;
ResponsiveListContainer.Body = Body;

export { ResponsiveListContainer };
export default ResponsiveListContainer;
