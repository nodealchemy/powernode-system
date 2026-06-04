// API client for the operator-facing CVE exposure read surface. Until this
// landed, CVE data was worker/MCP-only — the feed job ingests CVEs and the
// CVE Responder agent's autonomy tick produces exposures, but there was no
// operator surface to render the fleet's CVE risk posture. This is read-only
// (index/show); remediation flows through the CVE Responder agent.
//
// Backend: Api::V1::System::CveExposuresController
//   index/show → system.cve.read
//
// A CveExposure has no direct account_id; it scopes through
// node_module_version → node_module. The controller paginates index and
// accepts severity (filters the joined CVE) + state (alias: status) filters.
import { apiClient } from '@/shared/services/apiClient';
import type { SystemCveExposure } from '@system/features/system/types/system.types';
import { extractData, extractPaginated } from './helpers';
import type {
  ApiEnvelope,
  PaginatedEnvelope,
  PaginationMeta,
  PaginationParams,
} from './types';

export interface CveExposureFilters extends PaginationParams {
  // One of System::Cve::SEVERITIES — filters on the joined CVE.
  severity?: string;
  // One of System::CveExposure::STATES. `status` is accepted by the backend
  // as an alias for `state`; we expose `state` as the canonical filter.
  state?: string;
}

export const cveApi = {
  list: async (
    params?: CveExposureFilters
  ): Promise<{ cve_exposures: SystemCveExposure[]; meta: PaginationMeta }> => {
    const response = await apiClient.get<
      PaginatedEnvelope<{ cve_exposures: SystemCveExposure[] }>
    >('/system/cve_exposures', { params });
    return extractPaginated(response);
  },

  get: async (id: string): Promise<SystemCveExposure> => {
    const response = await apiClient.get<ApiEnvelope<{ cve_exposure: SystemCveExposure }>>(
      `/system/cve_exposures/${id}`
    );
    return extractData(response).cve_exposure;
  },
};
