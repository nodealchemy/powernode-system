import { formatVolumeSize } from './volumeSize';

describe('formatVolumeSize', () => {
  it('renders a gigabyte value on core ladder, with core decimals', () => {
    expect(formatVolumeSize(100)).toBe('100.0 GB');
    expect(formatVolumeSize(500)).toBe('500.0 GB');
  });

  it('rolls over to TB at 1024 GB, exactly where the copies it replaced did', () => {
    expect(formatVolumeSize(1023)).toBe('1023.0 GB');
    expect(formatVolumeSize(1024)).toBe('1.0 TB');
    expect(formatVolumeSize(2048)).toBe('2.0 TB');
    expect(formatVolumeSize(1536)).toBe('1.5 TB');
  });

  it('keeps going past TB, which the hand-rolled copies could not', () => {
    // The replaced bodies stopped at TB: a petabyte volume read as
    // '1048576.0 TB'. Core's ladder carries to PB.
    expect(formatVolumeSize(1024 * 1024)).toBe('1.0 PB');
  });

  // The whole reason this helper exists rather than a bare formatFileSize call
  // at each site. A raw gigabyte value handed to the byte formatter renders a
  // 100 GB volume as '100 B', which looks like a plausible size rather than an
  // obvious bug.
  it('converts the unit, so a GB value never reaches the byte formatter raw', () => {
    expect(formatVolumeSize(100)).not.toBe('100 B');
    expect(formatVolumeSize(0)).toBe('0 B');
  });
});
