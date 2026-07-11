import React from 'react';
import { AlertTriangle } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import type { SystemNodeInstance } from '@system/features/system/types/system.types';

interface BootImageDriftBadgeProps {
  /** The instance to inspect for boot-image drift. */
  instance: Pick<SystemNodeInstance, 'boot_image_drifted' | 'booted_image_git_sha' | 'promoted_image_git_sha'>;
  /** Badge size — defaults to 'xs' to match inline row usage. */
  size?: 'xs' | 'sm' | 'md' | 'lg';
  className?: string;
}

const shortSha = (sha?: string | null) => (sha ? sha.slice(0, 12) : 'unknown');

/**
 * BootImageDriftBadge - warns when a node instance is running a boot
 * image older than the one currently promoted for its platform.
 *
 * Renders nothing unless `instance.boot_image_drifted` is true (i.e. both
 * the booted and promoted git_sha are known AND they differ — see
 * System::NodeInstanceSerializer / campaign 019f505f). Purely presentational;
 * callers gate visibility the same way they gate the rest of the instance
 * view (no additional permission check here).
 */
export const BootImageDriftBadge: React.FC<BootImageDriftBadgeProps> = ({
  instance,
  size = 'xs',
  className = '',
}) => {
  if (!instance.boot_image_drifted) return null;

  return (
    <span
      title={`Booted from ${shortSha(instance.booted_image_git_sha)} → promoted image is ${shortSha(instance.promoted_image_git_sha)}`}
    >
      <Badge variant="warning" size={size} icon={<AlertTriangle className="w-3 h-3" />} className={className}>
        Boot image outdated
      </Badge>
    </span>
  );
};

export default BootImageDriftBadge;
