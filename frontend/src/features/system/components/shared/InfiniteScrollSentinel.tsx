import React, { useEffect, useRef } from 'react';

/**
 * Drop-in viewport sentinel for infinite scroll. Uses IntersectionObserver
 * with a 200px rootMargin so paging fires *before* the user reaches the
 * bottom — keeps the scroll smooth instead of stalling at the edge.
 *
 * @example
 *   <InfiniteScrollSentinel
 *     onIntersect={list.loadMore}
 *     enabled={list.hasMore && !list.loadingMore}
 *   />
 */
export interface InfiniteScrollSentinelProps {
  /** Called when the sentinel enters the viewport. */
  onIntersect: () => void;
  /** Disables the observer when false (e.g., no more pages, or a fetch is
   *  in flight). The element still mounts so layout doesn't shift. */
  enabled: boolean;
  /** Pixels before the viewport edge to trigger. Default 200. */
  rootMargin?: string;
  className?: string;
}

export const InfiniteScrollSentinel: React.FC<InfiniteScrollSentinelProps> = ({
  onIntersect,
  enabled,
  rootMargin = '200px',
  className = '',
}) => {
  const ref = useRef<HTMLDivElement>(null);
  const onIntersectRef = useRef(onIntersect);

  useEffect(() => { onIntersectRef.current = onIntersect; }, [onIntersect]);

  useEffect(() => {
    if (!enabled) return;
    const node = ref.current;
    if (!node) return;

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0]?.isIntersecting) {
          onIntersectRef.current();
        }
      },
      { rootMargin }
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [enabled, rootMargin]);

  return <div ref={ref} aria-hidden className={`h-1 w-full ${className}`} />;
};

export default InfiniteScrollSentinel;
