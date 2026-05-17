// Cloudflare DNS record management types.
// Plan reference: CF-DNS (Cloudflare DNS record management).

export type DnsRecordType =
  | 'A' | 'AAAA' | 'CNAME' | 'TXT' | 'MX' | 'SRV' | 'NS' | 'CAA' | 'PTR';

export interface CloudflareZone {
  id: string;
  name: string;
  status: string;
  type?: string;
  created_on?: string;
  modified_on?: string;
  paused?: boolean;
  account?: { id?: string; name?: string };
  // Cloudflare returns many other fields; we don't enumerate every one
  [key: string]: unknown;
}

export interface DnsRecord {
  id: string;
  zone_id: string;
  zone_name?: string;
  type: DnsRecordType;
  name: string;
  content: string;
  ttl: number;
  proxied?: boolean;
  priority?: number;
  comment?: string | null;
  tags?: string[];
  created_on?: string;
  modified_on?: string;
  [key: string]: unknown;
}

export interface ZonesListResponse {
  zones: CloudflareZone[];
}

export interface RecordsListResponse {
  records: DnsRecord[];
}

export interface CreateRecordRequest {
  zone_id: string;
  type: DnsRecordType;
  name: string;
  content: string;
  ttl?: number;
  proxied?: boolean;
  priority?: number;
  comment?: string;
  tags?: string[];
}

export interface UpdateRecordRequest {
  zone_id: string;
  type?: DnsRecordType;
  name?: string;
  content?: string;
  ttl?: number;
  proxied?: boolean;
  priority?: number;
  comment?: string;
  tags?: string[];
}
