import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';

// Ingress routes — read-only operator view of the Traefik routers the
// platform derives from each issued ACME certificate. One projection per
// System::AcmeCertificate row; routers are derived by TraefikConfigWriter
// (the same source TraefikConfigWriter.routers_for(cert) feeds the live
// dynamic config). The frontend NEVER mutates ingress here — exposing a new
// service is approval-gated through the Concierge mission path.
//
// Plan reference: Phase 2c (Ingress).
//
// Contract: GET /api/v1/system/ingress_routes  (optional ?status=...)
//   render_success(routes: [ <RouteProjection>, ... ])

const BASE = '/system/ingress_routes';

/** Cert lifecycle status, mirrored from System::AcmeCertificate#status. */
export type IngressRouteStatus =
  | 'pending'
  | 'issuing'
  | 'valid'
  | 'renewing'
  | 'revoked';

/**
 * One derived Traefik router for an ingress route. Mirrors the entries
 * TraefikConfigWriter produces for a cert (node-api, frontend catchall, etc.).
 * The frontend-facing catchall router carries `path_prefix: null` (or "/").
 */
export interface IngressRouter {
  name: string;
  path_prefix: string | null;
  backend_service: string;
  backend_url: string;
  entrypoint: string;
  tls_resolver: string;
}

/**
 * One ingress route — derived from a single System::AcmeCertificate row.
 * Account-scoped server-side. All fields are read-only projections; there is
 * no create/update/delete surface (intentionally — see module docstring).
 */
export interface IngressRoute {
  id: string;
  common_name: string;
  sans: string[];
  /** Derived Traefik host matcher, e.g. Host(`cn`) [ || Host(`extra`)... ]. */
  host_rule: string;
  status: IngressRouteStatus;
  /** true iff status === 'valid' (routers are live in Traefik). */
  active: boolean;
  issuer: string | null;
  issued_at: string | null;
  expires_at: string | null;
  /** floor((expires_at - now)/1.day); null when there's no expiry. */
  days_until_expiry: number | null;
  routers: IngressRouter[];
  /** Derived convenience list of public URLs, e.g. https://cn/. */
  public_endpoints: string[];
}

export interface IngressRoutesListResponse {
  routes: IngressRoute[];
}

export const ingressApi = {
  /**
   * List the derived ingress routes for the current account. Optional
   * `status` narrows to a single cert lifecycle state.
   */
  listRoutes: async (status?: IngressRouteStatus): Promise<IngressRoute[]> => {
    const params = status ? { status } : undefined;
    const response = await apiClient.get<ApiEnvelope<IngressRoutesListResponse>>(BASE, {
      params,
    });
    return extractData(response).routes ?? [];
  },
};
