import { useAutonomyConfig } from '@/shared/hooks/useAutonomyConfig';
import type { AutonomyConfigSource } from '@/shared/types/autonomy';

/**
 * System extension's AutonomyConfigSource — points the shared
 * useAutonomyConfig hook at the System Settings API endpoints
 * (Phase 8 controller). Maps the 5 system agents (Fleet Autonomy,
 * SDWAN Manager, CVE Responder, Disk Image Manager, Runtime Manager)
 * onto their PATCH role identifiers.
 */
export const systemAutonomyConfigSource: AutonomyConfigSource = {
  fetchEndpoint: '/system/autonomy',
  updateEndpoint: '/system/autonomy',
  roleForAgent: (name: string): string | undefined => {
    const lower = name.toLowerCase();
    if (lower.includes('fleet')) return 'fleet';
    if (lower.includes('sdwan')) return 'sdwan';
    if (lower.includes('cve')) return 'cve';
    if (lower.includes('disk image')) return 'disk_image';
    if (lower.includes('runtime')) return 'runtime';
    return 'manual';
  },
};

export function useSystemAutonomyConfig() {
  return useAutonomyConfig(systemAutonomyConfigSource);
}
