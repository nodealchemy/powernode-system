import React from 'react';
import { render, screen } from '@testing-library/react';
import { BootImageDriftBadge } from './BootImageDriftBadge';

describe('BootImageDriftBadge', () => {
  it('renders nothing when boot_image_drifted is false', () => {
    const { container } = render(
      <BootImageDriftBadge
        instance={{
          boot_image_drifted: false,
          booted_image_git_sha: 'abc123def456789',
          promoted_image_git_sha: 'zzz999yyy888777',
        }}
      />,
    );
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when boot_image_drifted is undefined', () => {
    const { container } = render(<BootImageDriftBadge instance={{}} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders the warning badge when boot_image_drifted is true', () => {
    render(
      <BootImageDriftBadge
        instance={{
          boot_image_drifted: true,
          booted_image_git_sha: 'abc123def456789',
          promoted_image_git_sha: 'zzz999yyy888777',
        }}
      />,
    );
    expect(screen.getByText('Boot image outdated')).toBeInTheDocument();
  });

  it('includes shortened booted and promoted shas in the tooltip', () => {
    render(
      <BootImageDriftBadge
        instance={{
          boot_image_drifted: true,
          booted_image_git_sha: 'abc123def456789',
          promoted_image_git_sha: 'zzz999yyy888777',
        }}
      />,
    );
    const badge = screen.getByText('Boot image outdated');
    const tooltipHost = badge.closest('[title]');
    expect(tooltipHost).not.toBeNull();
    expect(tooltipHost).toHaveAttribute(
      'title',
      'Booted from abc123def456 → promoted image is zzz999yyy888',
    );
  });

  it('falls back to "unknown" in the tooltip when a sha is missing', () => {
    render(
      <BootImageDriftBadge
        instance={{
          boot_image_drifted: true,
          booted_image_git_sha: null,
          promoted_image_git_sha: 'zzz999yyy888777',
        }}
      />,
    );
    const badge = screen.getByText('Boot image outdated');
    const tooltipHost = badge.closest('[title]');
    expect(tooltipHost).toHaveAttribute(
      'title',
      'Booted from unknown → promoted image is zzz999yyy888',
    );
  });
});
