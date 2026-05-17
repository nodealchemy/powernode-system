// ACME DNS credentials + certificates — operator-facing types that
// mirror System::AcmeDnsCredential + System::AcmeCertificate.
//
// Plan reference: Decentralized Federation §J + P2.5.

export type AcmeDnsProvider =
  | 'cloudflare'
  | 'route53'
  | 'gcloud'
  | 'digitalocean'
  | 'hetzner'
  | 'porkbun'
  | 'ovh';

export type AcmeDnsCredentialStatus = 'untested' | 'valid' | 'invalid' | 'expired';

export interface AcmeDnsCredentialSummary {
  id: string;
  name: string;
  provider: AcmeDnsProvider;
  status: AcmeDnsCredentialStatus;
  last_validated_at: string | null;
  created_at: string;
  updated_at: string;
  needs_revalidation: boolean;
}

export interface AcmeDnsCredentialDetail extends AcmeDnsCredentialSummary {
  metadata: Record<string, unknown>;
  certificates_count: number;
  required_fields: string[];
}

export interface SupportedProvider {
  slug: AcmeDnsProvider;
  required_fields: string[];
  description: string;
}

export interface AcmeDnsCredentialsListResponse {
  credentials: AcmeDnsCredentialSummary[];
  count: number;
  supported_providers: SupportedProvider[];
}

export interface AcmeDnsCredentialCreateRequest {
  name: string;
  provider: AcmeDnsProvider;
  // Provider-specific. Cloudflare: { api_token }.
  // DigitalOcean: { auth_token }. Route53: { access_key_id, secret_access_key, region }. Etc.
  credentials: Record<string, string>;
  metadata?: Record<string, unknown>;
}

export interface AcmeDnsCredentialRotateRequest {
  credentials: Record<string, string>;
}

export interface AcmeDnsCredentialTestResponse {
  ok: boolean;
  reason: string;
  details?: Record<string, unknown>;
  credential: AcmeDnsCredentialDetail;
}

// === Certificates ===

export type AcmeCertificateStatus =
  | 'pending'
  | 'issuing'
  | 'valid'
  | 'renewing'
  | 'expired'
  | 'revoked'
  | 'failed';

export type AcmeIssuer = 'letsencrypt-prod' | 'letsencrypt-staging' | 'internal-ca';

export interface AcmeCertificateSummary {
  id: string;
  common_name: string;
  sans: string[];
  status: AcmeCertificateStatus;
  issuer: AcmeIssuer | string;
  challenge_type: 'dns-01' | 'http-01' | 'tls-alpn-01';
  dns_credential_id: string | null;
  issued_at: string | null;
  expires_at: string | null;
  days_until_expiry: number | null;
  created_at: string;
  updated_at: string;
  vault_paths_present: boolean;
  terminal: boolean;
  last_renewal_error: string | null;
}

export interface AcmeCertificateDetail extends AcmeCertificateSummary {
  dns_credential_name: string | null;
  dns_credential_provider: string | null;
  traefik_resolver_name: string | null;
  metadata: Record<string, unknown>;
}

export interface AcmeCertificatesListResponse {
  certificates: AcmeCertificateSummary[];
  count: number;
  issuers: string[];
}

export interface AcmeCertificateCreateRequest {
  common_name: string;
  dns_credential_id: string;
  issuer: AcmeIssuer | string;
  // The ACME registration contact email. Persisted under metadata.acme_email.
  acme_email: string;
  sans?: string[];
  traefik_resolver_name?: string;
}

export interface AcmeCertificateActionResponse {
  ok: boolean;
  certificate: AcmeCertificateDetail;
}
