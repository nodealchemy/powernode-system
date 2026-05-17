import { apiClient } from '@/shared/services/apiClient';
import { extractData } from './helpers';
import type { ApiEnvelope } from './types';
import type {
  CloudflareZone,
  CreateRecordRequest,
  DnsRecord,
  RecordsListResponse,
  UpdateRecordRequest,
  ZonesListResponse,
} from '../../types/dns.types';

// Cloudflare DNS records API client — operator surface for managing
// records on zones the credential's api_token can already reach.
//
// Plan reference: CF-DNS (Cloudflare DNS record management).

const base = (credId: string) => `/system/acme_dns_credentials/${credId}`;

export const dnsRecordsApi = {
  listZones: async (credentialId: string, name?: string): Promise<CloudflareZone[]> => {
    const response = await apiClient.get<ApiEnvelope<ZonesListResponse>>(
      `${base(credentialId)}/zones`,
      { params: name ? { name } : {} },
    );
    return extractData(response).zones;
  },

  listRecords: async (
    credentialId: string,
    zoneId: string,
    filters?: { type?: string; name?: string },
  ): Promise<DnsRecord[]> => {
    const response = await apiClient.get<ApiEnvelope<RecordsListResponse>>(
      `${base(credentialId)}/records`,
      { params: { zone_id: zoneId, ...(filters ?? {}) } },
    );
    return extractData(response).records;
  },

  createRecord: async (
    credentialId: string,
    req: CreateRecordRequest,
  ): Promise<DnsRecord> => {
    const response = await apiClient.post<ApiEnvelope<{ record: DnsRecord }>>(
      `${base(credentialId)}/records`,
      req,
    );
    return extractData(response).record;
  },

  updateRecord: async (
    credentialId: string,
    recordId: string,
    req: UpdateRecordRequest,
  ): Promise<DnsRecord> => {
    const response = await apiClient.patch<ApiEnvelope<{ record: DnsRecord }>>(
      `${base(credentialId)}/records/${recordId}`,
      req,
    );
    return extractData(response).record;
  },

  deleteRecord: async (
    credentialId: string,
    recordId: string,
    zoneId: string,
  ): Promise<void> => {
    await apiClient.delete<ApiEnvelope<{ deleted: true }>>(
      `${base(credentialId)}/records/${recordId}`,
      { params: { zone_id: zoneId } },
    );
  },
};
