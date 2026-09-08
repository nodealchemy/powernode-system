import { formatFileSize } from '@/shared/utils/formatters';

const BYTES_PER_GB = 1024 ** 3;

/**
 * Renders a volume size that the API reports in GIGABYTES.
 *
 * Provider volumes carry `size_gb`, not a byte count, which is why the volume
 * screens could not simply adopt core's formatFileSize during the formatter
 * consolidation (IMP-c11d5ad755b8): that function takes BYTES, so handing it a
 * raw `size_gb` renders a 100 GB volume as '100 B'. Two hand-rolled copies were
 * left behind instead, and IMP-afe91410f14d converts them here.
 *
 * The gigabyte stays the domain unit — it is what the API sends and what an
 * operator asks for when creating a volume — and the LADDER is core's. This
 * multiplies into bytes once, in one place, so the unit conversion cannot be
 * forgotten at a call site and the GB/TB rollover matches every other size in
 * the product.
 *
 * @param sizeGb - size in gigabytes, as the API reports it
 * @returns the size on core's unit ladder, e.g. '100.0 GB' or '2.0 TB'
 */
export function formatVolumeSize(sizeGb: number): string {
  return formatFileSize(sizeGb * BYTES_PER_GB);
}
