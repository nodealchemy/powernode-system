import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { Globe, Send, Loader2 } from 'lucide-react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { logger } from '@/shared/utils/logger';
import { ConciergeMessage, type ConciergeChatMessage } from '../concierge/ConciergeMessage';
import { useConcierge } from '../../hooks/useConcierge';
import type { ConciergeMessage as BackendMessage } from '../../services/api/conciergeApi';
import { acmeDnsCredentialsApi } from '../../services/api/acmeDnsCredentialsApi';
import { sdwanApi } from '../../services/api/sdwanApi';
import type { AcmeDnsCredentialSummary } from '../../types/acme.types';
import type { SdwanNetwork, SdwanPeer } from '../../types/sdwan.types';

/**
 * Expose Service tab — an approval-gated wizard for publishing a service
 * publicly. It does NOT call any ingress executor or REST endpoint directly:
 * instead it reuses the Phase 1 Concierge mission compose path. On submit it
 * starts (or resumes) the operator's System Concierge conversation and sends a
 * natural-language "expose this service publicly" brief embedding the
 * structured fields. The platform's ConciergeService classifies the intent,
 * composes an approval-gated mission, and emits an inline approval card —
 * surfaced here via the same ConciergeMessage / ConciergeActionCard flow the
 * concierge panel uses. The operator approves/rejects in place.
 *
 * Permission gate: system.ingress.manage.
 *
 * Plan reference: Phase 2c (Ingress).
 */

type ServiceProtocol = 'http' | 'https';

interface ExposeServiceForm {
  service_hostname: string;
  service_protocol: ServiceProtocol;
  sdwan_network_id: string;
  sdwan_hub_peer_id: string;
  vip_cidr: string;
  backend_port: string;
  tls_issuer: string;
  dns_credential_id: string;
}

const EMPTY_FORM: ExposeServiceForm = {
  service_hostname: '',
  service_protocol: 'https',
  sdwan_network_id: '',
  sdwan_hub_peer_id: '',
  vip_cidr: '',
  backend_port: '',
  tls_issuer: 'letsencrypt',
  dns_credential_id: '',
};

function toDisplayMessage(msg: BackendMessage): ConciergeChatMessage {
  const role: ConciergeChatMessage['role'] =
    msg.role === 'tool' || msg.role === 'user' || msg.role === 'assistant' ? msg.role : 'assistant';
  return {
    id: msg.id,
    role,
    content: msg.content,
    timestamp: msg.created_at,
    metadata: msg.content_metadata,
  };
}

/**
 * Build the natural-language brief the Concierge classifies into an
 * "expose service publicly" mission. Clear intent first, then the structured
 * fields so the LLM and the deterministic classifier both have everything.
 */
function buildBrief(form: ExposeServiceForm): string {
  const lines = [
    'Expose a service publicly behind the ingress proxy with TLS. Please compose an approval-gated mission for this.',
    '',
    'Service details:',
    `- Public hostname: ${form.service_hostname}`,
    `- Protocol: ${form.service_protocol}`,
    `- Backend port: ${form.backend_port}`,
    `- SDWAN network: ${form.sdwan_network_id}`,
    `- SDWAN hub peer: ${form.sdwan_hub_peer_id}`,
    `- vip_cidr: ${form.vip_cidr}`,
    `- TLS issuer: ${form.tls_issuer}`,
    `- DNS credential: ${form.dns_credential_id}`,
  ];
  return lines.join('\n');
}

export const ExposeServicePanel: React.FC = () => {
  const { hasPermission } = usePermissions();
  const canManage = hasPermission('system.ingress.manage');
  const { addNotification } = useNotifications();

  const concierge = useConcierge(canManage);
  const [form, setForm] = useState<ExposeServiceForm>(EMPTY_FORM);
  const [submitting, setSubmitting] = useState(false);

  // Reference data for the select inputs. Sourced from existing list
  // endpoints — no new backend surface is invented.
  const [dnsCredentials, setDnsCredentials] = useState<AcmeDnsCredentialSummary[]>([]);
  const [networks, setNetworks] = useState<SdwanNetwork[]>([]);
  const [peers, setPeers] = useState<SdwanPeer[]>([]);

  useEffect(() => {
    if (!canManage) return;
    let cancelled = false;
    (async () => {
      try {
        const [creds, nets] = await Promise.all([
          acmeDnsCredentialsApi.list(),
          sdwanApi.getNetworks(),
        ]);
        if (cancelled) return;
        setDnsCredentials(creds.credentials);
        setNetworks(nets.networks);
      } catch (err) {
        logger.warn('[ExposeServicePanel] failed to load reference data', err);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [canManage]);

  // Peers depend on the selected network — fetched on change.
  useEffect(() => {
    if (!canManage || !form.sdwan_network_id) {
      setPeers([]);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const result = await sdwanApi.getPeers(form.sdwan_network_id);
        if (!cancelled) setPeers(result.peers);
      } catch (err) {
        logger.warn('[ExposeServicePanel] failed to load peers', err);
        if (!cancelled) setPeers([]);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [canManage, form.sdwan_network_id]);

  const setField = useCallback(
    <K extends keyof ExposeServiceForm>(key: K, value: ExposeServiceForm[K]) => {
      setForm((prev) => {
        const next = { ...prev, [key]: value };
        // Clear the dependent hub-peer selection when the network changes.
        if (key === 'sdwan_network_id') next.sdwan_hub_peer_id = '';
        return next;
      });
    },
    [],
  );

  const isValid = useMemo(
    () =>
      form.service_hostname.trim().length > 0 &&
      form.sdwan_network_id.trim().length > 0 &&
      form.sdwan_hub_peer_id.trim().length > 0 &&
      form.vip_cidr.trim().length > 0 &&
      form.backend_port.trim().length > 0 &&
      form.tls_issuer.trim().length > 0 &&
      form.dns_credential_id.trim().length > 0,
    [form],
  );

  const handleSubmit = useCallback(async () => {
    if (!isValid || submitting || !concierge.conversationId) return;
    setSubmitting(true);
    try {
      await concierge.send(buildBrief(form));
      addNotification({
        type: 'success',
        title: 'Expose request submitted',
        message: 'Review and approve the mission below to publish the service.',
      });
    } catch (err) {
      logger.error('[ExposeServicePanel] submit failed', err);
      addNotification({
        type: 'error',
        title: 'Submit failed',
        message: 'Could not submit the expose-service request.',
      });
    } finally {
      setSubmitting(false);
    }
  }, [isValid, submitting, concierge, form, addNotification]);

  if (!canManage) {
    return (
      <div className="p-12 text-center text-theme-secondary text-sm">
        You don't have permission to expose services. Ask an admin to grant
        <code className="mx-1 font-mono">system.ingress.manage</code>.
      </div>
    );
  }

  const conversationMessages = concierge.messages.map(toDisplayMessage);

  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
      <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden">
        <header className="px-4 py-3 border-b border-theme flex items-center gap-2">
          <Globe className="w-5 h-5 text-theme-info" />
          <h2 className="font-semibold text-theme-primary">Expose a service</h2>
        </header>

        <div className="p-4 space-y-4">
          <p className="text-xs text-theme-secondary">
            Describe the service to publish. Submitting composes an approval-gated mission via the
            System Concierge — nothing is exposed until you approve the plan in the conversation
            panel.
          </p>

          <Field label="Public hostname" htmlFor="expose-hostname">
            <input
              id="expose-hostname"
              type="text"
              value={form.service_hostname}
              onChange={(e) => setField('service_hostname', e.target.value)}
              placeholder="app.example.com"
              className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
            />
          </Field>

          <div className="grid grid-cols-2 gap-3">
            <Field label="Protocol" htmlFor="expose-protocol">
              <select
                id="expose-protocol"
                value={form.service_protocol}
                onChange={(e) => setField('service_protocol', e.target.value as ServiceProtocol)}
                className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
              >
                <option value="http">http</option>
                <option value="https">https</option>
              </select>
            </Field>

            <Field label="Backend port" htmlFor="expose-port">
              <input
                id="expose-port"
                type="number"
                value={form.backend_port}
                onChange={(e) => setField('backend_port', e.target.value)}
                placeholder="8080"
                className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
              />
            </Field>
          </div>

          <Field label="SDWAN network" htmlFor="expose-network">
            <select
              id="expose-network"
              value={form.sdwan_network_id}
              onChange={(e) => setField('sdwan_network_id', e.target.value)}
              className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
            >
              <option value="">Select a network…</option>
              {networks.map((net) => (
                <option key={net.id} value={net.id}>
                  {net.name} ({net.slug})
                </option>
              ))}
            </select>
          </Field>

          <Field label="SDWAN hub peer" htmlFor="expose-hub-peer">
            <select
              id="expose-hub-peer"
              value={form.sdwan_hub_peer_id}
              onChange={(e) => setField('sdwan_hub_peer_id', e.target.value)}
              disabled={!form.sdwan_network_id}
              className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary disabled:opacity-50"
            >
              <option value="">
                {form.sdwan_network_id ? 'Select a hub peer…' : 'Select a network first'}
              </option>
              {peers.map((peer) => (
                <option key={peer.id} value={peer.id}>
                  {peer.assigned_address} ({peer.status})
                </option>
              ))}
            </select>
          </Field>

          <Field label="VIP CIDR" htmlFor="expose-vip-cidr">
            <input
              id="expose-vip-cidr"
              type="text"
              value={form.vip_cidr}
              onChange={(e) => setField('vip_cidr', e.target.value)}
              placeholder="fd00:dead:beef::1/128"
              className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
            />
            <p className="mt-1 text-xs text-theme-tertiary">
              A host CIDR (typically /128 for IPv6 or /32 for IPv4) within the SDWAN network's /64.
            </p>
          </Field>

          <div className="grid grid-cols-2 gap-3">
            <Field label="TLS issuer" htmlFor="expose-issuer">
              <input
                id="expose-issuer"
                type="text"
                value={form.tls_issuer}
                onChange={(e) => setField('tls_issuer', e.target.value)}
                placeholder="letsencrypt"
                className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
              />
            </Field>

            <Field label="DNS credential" htmlFor="expose-dns-cred">
              <select
                id="expose-dns-cred"
                value={form.dns_credential_id}
                onChange={(e) => setField('dns_credential_id', e.target.value)}
                className="w-full px-3 py-2 rounded border border-theme bg-theme-surface text-sm text-theme-primary"
              >
                <option value="">Select a credential…</option>
                {dnsCredentials.map((cred) => (
                  <option key={cred.id} value={cred.id}>
                    {cred.name} ({cred.provider})
                  </option>
                ))}
              </select>
            </Field>
          </div>

          <div className="flex justify-end pt-2">
            <button
              type="button"
              onClick={() => void handleSubmit()}
              disabled={!isValid || submitting || !concierge.conversationId}
              className="inline-flex items-center gap-2 px-4 py-2 rounded-md text-sm font-medium bg-theme-interactive-primary text-white hover:opacity-90 disabled:opacity-50 transition-opacity"
            >
              {submitting ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <Send className="w-4 h-4" />
              )}
              {submitting ? 'Submitting…' : 'Submit expose request'}
            </button>
          </div>
        </div>
      </div>

      <div className="bg-theme-surface border border-theme rounded-lg overflow-hidden flex flex-col min-h-[24rem]">
        <header className="px-4 py-3 border-b border-theme">
          <h2 className="font-semibold text-theme-primary">Mission approval</h2>
          <p className="text-xs text-theme-secondary">
            {concierge.agentName
              ? `Connected to ${concierge.agentName}`
              : 'Submit the request to start the mission conversation'}
          </p>
        </header>

        {concierge.error && (
          <div className="px-4 py-2 bg-theme-danger text-theme-danger text-xs border-b border-theme">
            {concierge.error}
          </div>
        )}

        <div className="flex-1 overflow-auto p-4 space-y-3">
          {conversationMessages.length === 0 && !concierge.pending && (
            <p className="text-xs text-theme-tertiary italic">
              No mission yet. Fill out the form and submit to compose an approval-gated mission.
            </p>
          )}
          {conversationMessages.map((msg) => (
            <ConciergeMessage
              key={msg.id}
              message={msg}
              onConfirmAction={concierge.confirmAction}
            />
          ))}
          {concierge.pending && (
            <div className="text-xs text-theme-tertiary italic">Concierge is thinking…</div>
          )}
        </div>
      </div>
    </div>
  );
};

interface FieldProps {
  label: string;
  htmlFor: string;
  children: React.ReactNode;
}

const Field: React.FC<FieldProps> = ({ label, htmlFor, children }) => (
  <div>
    <label htmlFor={htmlFor} className="block text-xs font-medium text-theme-secondary mb-1">
      {label}
    </label>
    {children}
  </div>
);

export default ExposeServicePanel;
