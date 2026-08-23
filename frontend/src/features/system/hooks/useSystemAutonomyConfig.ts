import { useAutonomyConfig } from '@/shared/hooks/useAutonomyConfig';
import type { AutonomyConfigSource } from '@/shared/types/autonomy';
import { systemPolicyBucket } from '@system/features/system/autonomyBucket';

/**
 * System extension's AutonomyConfigSource — points the shared
 * useAutonomyConfig hook at the System Settings API endpoints
 * (Phase 8 controller).
 *
 * This used to also carry a `roleForAgent` map from agent display name onto a
 * coarse role string ('fleet' | 'sdwan' | 'cve' | 'disk_image' | 'runtime' |
 * 'manual'), sent as `agent_role` alongside a `policies` object. Nothing
 * server-side ever read either key: `System::AutonomyActions#update` parses
 * `params[:updates]` and returns 400 without it, so every save from the
 * Autonomy modal was rejected and no operator toggle was ever persisted
 * (IMP-bef43160636f). The mapping was lossy in the same direction the finding
 * describes — a substring match onto a name, from which no specific policy row
 * can be recovered. `save()` now returns each row's own `scope` + `agent_id`,
 * which the GET already ships, so no name→role mapping is needed at all.
 */
export const systemAutonomyConfigSource: AutonomyConfigSource = {
  fetchEndpoint: '/system/autonomy',
  updateEndpoint: '/system/autonomy',
  bucketForRow: systemPolicyBucket,
};

export function useSystemAutonomyConfig() {
  return useAutonomyConfig(systemAutonomyConfigSource);
}
