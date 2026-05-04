import React, { useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanFirewallAction,
  SdwanFirewallDirection,
  SdwanFirewallProtocol,
  SdwanSelector,
} from '../../types/sdwan.types';

interface FirewallRuleCreateModalProps {
  isOpen: boolean;
  networkId: string;
  onClose: () => void;
  onCreated: () => void;
}

type SelectorKind = 'all' | 'cidr' | 'peer_id' | 'tag';

/**
 * FirewallRuleCreateModal — minimal-but-complete form for the four-kind
 * selector grammar. Tag selectors compile to wildcard until slice 5
 * populates nft sets — the form annotates this so operators understand
 * the deferred semantics.
 */
export const FirewallRuleCreateModal: React.FC<FirewallRuleCreateModalProps> = ({
  isOpen,
  networkId,
  onClose,
  onCreated,
}) => {
  const { addNotification } = useNotifications();
  const [name, setName] = useState('');
  const [priority, setPriority] = useState<number>(1000);
  const [action, setAction] = useState<SdwanFirewallAction>('accept');
  const [direction, setDirection] = useState<SdwanFirewallDirection>('ingress');
  const [protocol, setProtocol] = useState<SdwanFirewallProtocol>('any');
  const [srcKind, setSrcKind] = useState<SelectorKind>('all');
  const [srcValue, setSrcValue] = useState('');
  const [dstKind, setDstKind] = useState<SelectorKind>('all');
  const [dstValue, setDstValue] = useState('');
  const [portFrom, setPortFrom] = useState<string>('');
  const [portTo, setPortTo] = useState<string>('');
  const [submitting, setSubmitting] = useState(false);

  const reset = () => {
    setName(''); setPriority(1000); setAction('accept'); setDirection('ingress');
    setProtocol('any'); setSrcKind('all'); setSrcValue(''); setDstKind('all');
    setDstValue(''); setPortFrom(''); setPortTo(''); setSubmitting(false);
  };

  const handleClose = () => {
    if (submitting) return;
    reset();
    onClose();
  };

  const buildSelector = (kind: SelectorKind, value: string): SdwanSelector | undefined => {
    switch (kind) {
      case 'all':     return { all: true };
      case 'cidr':    return value ? { cidr: value } : undefined;
      case 'peer_id': return value ? { peer_id: value } : undefined;
      case 'tag':     return value ? { tag: value } : undefined;
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!name.trim()) {
      addNotification({ type: 'error', message: 'Rule name is required' });
      return;
    }
    if ((portFrom !== '') !== (portTo !== '')) {
      addNotification({ type: 'error', message: 'Provide both port_from and port_to, or neither' });
      return;
    }
    if (portFrom !== '' && !['tcp', 'udp'].includes(protocol)) {
      addNotification({ type: 'error', message: 'Port range only applies to tcp or udp' });
      return;
    }
    setSubmitting(true);
    try {
      await sdwanApi.createFirewallRule(networkId, {
        name: name.trim(),
        priority,
        action,
        direction,
        protocol,
        src_selector: buildSelector(srcKind, srcValue),
        dst_selector: buildSelector(dstKind, dstValue),
        port_range: portFrom !== '' ? { from: Number(portFrom), to: Number(portTo) } : null,
      });
      addNotification({ type: 'success', message: `Rule "${name}" created` });
      onCreated();
      reset();
      onClose();
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Failed to create rule';
      addNotification({ type: 'error', message: msg });
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={handleClose} title="Add firewall rule">
      <form onSubmit={handleSubmit} className="space-y-3">
        <div className="grid grid-cols-3 gap-3">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
              placeholder="e.g. allow-ssh"
              autoFocus
              disabled={submitting}
            />
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Priority</label>
            <input
              type="number"
              value={priority}
              onChange={(e) => setPriority(Number(e.target.value))}
              className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
              min={0}
              disabled={submitting}
            />
          </div>
        </div>

        <div className="grid grid-cols-3 gap-3">
          <SelectField label="Action" value={action} onChange={(v) => setAction(v as SdwanFirewallAction)}
                       options={['accept', 'drop', 'reject']} disabled={submitting} />
          <SelectField label="Direction" value={direction} onChange={(v) => setDirection(v as SdwanFirewallDirection)}
                       options={['ingress', 'egress', 'both']} disabled={submitting} />
          <SelectField label="Protocol" value={protocol} onChange={(v) => setProtocol(v as SdwanFirewallProtocol)}
                       options={['any', 'tcp', 'udp', 'icmp6']} disabled={submitting} />
        </div>

        <SelectorField label="Source" kind={srcKind} value={srcValue}
                       onKindChange={setSrcKind} onValueChange={setSrcValue} disabled={submitting} />
        <SelectorField label="Destination" kind={dstKind} value={dstValue}
                       onKindChange={setDstKind} onValueChange={setDstValue} disabled={submitting} />

        {['tcp', 'udp'].includes(protocol) && (
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">Port from (optional)</label>
              <input type="number" value={portFrom} onChange={(e) => setPortFrom(e.target.value)} min={1} max={65535}
                     className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
                     disabled={submitting} />
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">Port to</label>
              <input type="number" value={portTo} onChange={(e) => setPortTo(e.target.value)} min={1} max={65535}
                     className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary"
                     disabled={submitting} />
            </div>
          </div>
        )}

        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={handleClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting || !name.trim()}>
            {submitting ? 'Creating…' : 'Create rule'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};

const SelectField: React.FC<{
  label: string;
  value: string;
  onChange: (v: string) => void;
  options: string[];
  disabled?: boolean;
}> = ({ label, value, onChange, options, disabled }) => (
  <div>
    <label className="block text-sm font-medium text-theme-primary mb-1">{label}</label>
    <select value={value} onChange={(e) => onChange(e.target.value)} disabled={disabled}
            className="w-full p-2 bg-theme-input border border-theme-border rounded text-theme-primary">
      {options.map((o) => <option key={o} value={o}>{o}</option>)}
    </select>
  </div>
);

const SelectorField: React.FC<{
  label: string;
  kind: SelectorKind;
  value: string;
  onKindChange: (k: SelectorKind) => void;
  onValueChange: (v: string) => void;
  disabled?: boolean;
}> = ({ label, kind, value, onKindChange, onValueChange, disabled }) => {
  const placeholder = kind === 'cidr' ? 'fdf8:.../64'
    : kind === 'peer_id' ? '019…' : kind === 'tag' ? 'production' : '';
  return (
    <div>
      <label className="block text-sm font-medium text-theme-primary mb-1">{label}</label>
      <div className="grid grid-cols-3 gap-2">
        <select value={kind} onChange={(e) => onKindChange(e.target.value as SelectorKind)} disabled={disabled}
                className="p-2 bg-theme-input border border-theme-border rounded text-theme-primary">
          <option value="all">any</option>
          <option value="cidr">cidr</option>
          <option value="peer_id">peer</option>
          <option value="tag">tag (deferred)</option>
        </select>
        {kind !== 'all' && (
          <input type="text" value={value} onChange={(e) => onValueChange(e.target.value)}
                 placeholder={placeholder} disabled={disabled}
                 className="col-span-2 p-2 bg-theme-input border border-theme-border rounded text-theme-primary font-mono text-sm" />
        )}
      </div>
    </div>
  );
};
