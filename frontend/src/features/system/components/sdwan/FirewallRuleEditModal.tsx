import React, { useEffect, useState } from 'react';
import { Modal } from '@/shared/components/ui/Modal';
import { Button } from '@/shared/components/ui/Button';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { sdwanApi } from '../../services/api/sdwanApi';
import type {
  SdwanFirewallRule,
  SdwanFirewallAction,
  SdwanFirewallDirection,
  SdwanFirewallProtocol,
  SdwanSelector,
} from '../../types/sdwan.types';

interface FirewallRuleEditModalProps {
  isOpen: boolean;
  networkId: string;
  rule: SdwanFirewallRule | null;
  onClose: () => void;
  onSaved: () => void;
}

type SelectorKind = 'all' | 'cidr' | 'peer_id' | 'tag';

function selectorKind(sel?: SdwanSelector): SelectorKind {
  if (!sel) return 'all';
  if ('all' in sel && (sel as { all?: boolean }).all) return 'all';
  if ('peer_id' in sel) return 'peer_id';
  if ('cidr' in sel) return 'cidr';
  if ('tag' in sel) return 'tag';
  return 'all';
}

function selectorValue(sel?: SdwanSelector): string {
  if (!sel) return '';
  if ('peer_id' in sel) return (sel as { peer_id: string }).peer_id;
  if ('cidr' in sel) return (sel as { cidr: string }).cidr;
  if ('tag' in sel) return (sel as { tag: string }).tag;
  return '';
}

export const FirewallRuleEditModal: React.FC<FirewallRuleEditModalProps> = ({
  isOpen, networkId, rule, onClose, onSaved,
}) => {
  const { addNotification } = useNotifications();
  const [name, setName] = useState('');
  const [priority, setPriority] = useState<number>(1000);
  const [action, setAction] = useState<SdwanFirewallAction>('accept');
  const [direction, setDirection] = useState<SdwanFirewallDirection>('ingress');
  const [protocol, setProtocol] = useState<SdwanFirewallProtocol>('any');
  const [enabled, setEnabled] = useState(true);
  const [srcKind, setSrcKind] = useState<SelectorKind>('all');
  const [srcValue, setSrcValue] = useState('');
  const [dstKind, setDstKind] = useState<SelectorKind>('all');
  const [dstValue, setDstValue] = useState('');
  const [portFrom, setPortFrom] = useState<string>('');
  const [portTo, setPortTo] = useState<string>('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (!rule) return;
    setName(rule.name);
    setPriority(rule.priority);
    setAction(rule.action);
    setDirection(rule.direction);
    setProtocol(rule.protocol);
    setEnabled(rule.enabled);
    setSrcKind(selectorKind(rule.src_selector));
    setSrcValue(selectorValue(rule.src_selector));
    setDstKind(selectorKind(rule.dst_selector));
    setDstValue(selectorValue(rule.dst_selector));
    setPortFrom(rule.port_range ? String(rule.port_range.from) : '');
    setPortTo(rule.port_range ? String(rule.port_range.to) : '');
  }, [rule]);

  if (!rule) return null;

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
    if ((portFrom !== '') !== (portTo !== '')) {
      addNotification({ type: 'error', message: 'Provide both port_from and port_to, or neither' });
      return;
    }
    setSubmitting(true);
    try {
      await sdwanApi.updateFirewallRule(networkId, rule.id, {
        name: name.trim(),
        priority, action, direction, protocol, enabled,
        src_selector: buildSelector(srcKind, srcValue),
        dst_selector: buildSelector(dstKind, dstValue),
        port_range: portFrom !== '' ? { from: Number(portFrom), to: Number(portTo) } : null,
      });
      addNotification({ type: 'success', message: `Rule "${name}" updated` });
      onSaved();
      onClose();
    } catch (err) {
      addNotification({ type: 'error', message: err instanceof Error ? err.message : 'Update failed' });
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal isOpen={isOpen} onClose={() => !submitting && onClose()} title={`Edit ${rule.name}`}>
      <form onSubmit={handleSubmit} className="space-y-3">
        <div className="grid grid-cols-3 gap-3">
          <div className="col-span-2">
            <label className="block text-sm font-medium text-theme-primary mb-1">Name</label>
            <input type="text" value={name} onChange={(e) => setName(e.target.value)}
                   className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                   disabled={submitting} />
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Priority</label>
            <input type="number" value={priority} onChange={(e) => setPriority(Number(e.target.value))}
                   className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                   min={0} disabled={submitting} />
          </div>
        </div>
        <div className="grid grid-cols-3 gap-3">
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Action</label>
            <select value={action} onChange={(e) => setAction(e.target.value as SdwanFirewallAction)}
                    className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                    disabled={submitting}>
              <option value="accept">accept</option>
              <option value="drop">drop</option>
              <option value="reject">reject</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Direction</label>
            <select value={direction} onChange={(e) => setDirection(e.target.value as SdwanFirewallDirection)}
                    className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                    disabled={submitting}>
              <option value="ingress">ingress</option>
              <option value="egress">egress</option>
              <option value="both">both</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium text-theme-primary mb-1">Protocol</label>
            <select value={protocol} onChange={(e) => setProtocol(e.target.value as SdwanFirewallProtocol)}
                    className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                    disabled={submitting}>
              <option value="any">any</option>
              <option value="tcp">tcp</option>
              <option value="udp">udp</option>
              <option value="icmp6">icmp6</option>
            </select>
          </div>
        </div>
        {[
          { label: 'Source', kind: srcKind, value: srcValue, setKind: setSrcKind, setValue: setSrcValue },
          { label: 'Destination', kind: dstKind, value: dstValue, setKind: setDstKind, setValue: setDstValue },
        ].map((row) => (
          <div key={row.label}>
            <label className="block text-sm font-medium text-theme-primary mb-1">{row.label}</label>
            <div className="grid grid-cols-3 gap-2">
              <select value={row.kind} onChange={(e) => row.setKind(e.target.value as SelectorKind)}
                      className="p-2 bg-theme-input border border-theme rounded text-theme-primary"
                      disabled={submitting}>
                <option value="all">any</option>
                <option value="cidr">cidr</option>
                <option value="peer_id">peer</option>
                <option value="tag">tag (deferred)</option>
              </select>
              {row.kind !== 'all' && (
                <input type="text" value={row.value} onChange={(e) => row.setValue(e.target.value)}
                       className="col-span-2 p-2 bg-theme-input border border-theme rounded text-theme-primary font-mono text-sm"
                       disabled={submitting} />
              )}
            </div>
          </div>
        ))}
        {['tcp', 'udp'].includes(protocol) && (
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">Port from</label>
              <input type="number" value={portFrom} onChange={(e) => setPortFrom(e.target.value)} min={1} max={65535}
                     className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                     disabled={submitting} />
            </div>
            <div>
              <label className="block text-sm font-medium text-theme-primary mb-1">Port to</label>
              <input type="number" value={portTo} onChange={(e) => setPortTo(e.target.value)} min={1} max={65535}
                     className="w-full p-2 bg-theme-input border border-theme rounded text-theme-primary"
                     disabled={submitting} />
            </div>
          </div>
        )}
        <div>
          <label className="flex items-center gap-2 cursor-pointer">
            <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} disabled={submitting} />
            <span className="text-sm text-theme-primary">Rule enabled</span>
          </label>
        </div>
        <div className="flex justify-end gap-2 pt-2">
          <Button variant="secondary" onClick={onClose} disabled={submitting}>Cancel</Button>
          <Button variant="primary" type="submit" disabled={submitting || !name.trim()}>
            {submitting ? 'Saving…' : 'Save'}
          </Button>
        </div>
      </form>
    </Modal>
  );
};
