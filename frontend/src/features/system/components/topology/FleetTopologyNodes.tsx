// Custom xyflow node renderers for the fleet graph.
//
// Same convention as SystemTopology's renderers: the library wrapper is
// stripped to transparent in the CSS file and each renderer owns its own
// themed card. Every colour is a theme token — nothing raw.
//
// Handles are fixed (one target on top, one source on bottom) rather than
// SystemTopology's server-stamped multi-handle counts: the fleet layout is
// computed client-side and every tier flows straight down, so a single
// centred handle per side is enough.

import React from 'react';
import { Handle, Position, type NodeProps } from '@xyflow/react';
import { Boxes, Cpu, Network as NetworkIcon, Server, AlertTriangle } from 'lucide-react';
import type {
  FleetGroupNodeData,
  FleetInstanceNodeData,
  FleetNetworkNodeData,
  FleetNodeCardData,
} from './fleetTopologyLayout';
import type { FleetNodeHealth } from './fleetTopologyData';

const TopHandle: React.FC = () => <Handle type="target" position={Position.Top} />;
const BottomHandle: React.FC = () => <Handle type="source" position={Position.Bottom} />;

// ─── Group (provider / platform lane) ───────────────────────────────

export const FleetGroupNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as FleetGroupNodeData;
  return (
    <div className="px-4 py-3 bg-theme-info-bg border-2 border-theme-info-border rounded-lg shadow-sm w-[220px] text-center">
      <BottomHandle />
      <Boxes className="w-5 h-5 mx-auto mb-1 text-theme-info-fg" />
      <div className="font-semibold text-sm text-theme-info-fg truncate" title={d.label}>
        {d.label}
      </div>
      <div className="text-[10px] text-theme-secondary mt-0.5">
        {groupKindLabel(d.kind)} · {d.node_count} node{d.node_count === 1 ? '' : 's'} ·{' '}
        {d.instance_count} instance{d.instance_count === 1 ? '' : 's'}
      </div>
    </div>
  );
};

function groupKindLabel(kind: string): string {
  switch (kind) {
    case 'provider':
      return 'provider';
    case 'platform':
      return 'platform';
    case 'template':
      return 'template';
    default:
      return 'ungrouped';
  }
}

// ─── Node card ──────────────────────────────────────────────────────

export const FleetNodeCard: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as FleetNodeCardData;
  const visibleModules = d.modules.slice(0, 3);
  const extraModules = d.modules.length - visibleModules.length;

  return (
    <div className="px-3 py-2 bg-theme-surface border-2 border-theme rounded-lg shadow-sm w-[200px]">
      <TopHandle />
      <BottomHandle />
      <div className="flex items-center gap-2">
        <Server className="w-4 h-4 text-theme-secondary shrink-0" />
        <span className="font-medium text-sm text-theme-primary truncate" title={d.label}>
          {d.label}
        </span>
        <span
          className={`w-2 h-2 rounded-full shrink-0 ml-auto ${nodeHealthColor(d.health)}`}
          title={nodeHealthLabel(d.health)}
        />
      </div>
      <div className="text-[10px] text-theme-secondary mt-1">
        {d.running_count}/{d.instance_count} running
        {d.template_name ? ` · ${d.template_name}` : ''}
      </div>
      {visibleModules.length > 0 && (
        <div className="flex flex-wrap gap-1 mt-1.5">
          {visibleModules.map((name) => (
            <span
              key={name}
              className="px-1.5 py-0.5 text-[9px] rounded bg-theme-background-secondary text-theme-secondary truncate max-w-[84px]"
              title={name}
            >
              {name}
            </span>
          ))}
          {extraModules > 0 && (
            <span className="px-1.5 py-0.5 text-[9px] rounded bg-theme-background-secondary text-theme-secondary">
              +{extraModules}
            </span>
          )}
        </div>
      )}
      {d.hidden_instance_count > 0 && (
        <div className="text-[9px] text-theme-tertiary mt-1">
          +{d.hidden_instance_count} more instance{d.hidden_instance_count === 1 ? '' : 's'} not shown
        </div>
      )}
    </div>
  );
};

// ─── Instance ───────────────────────────────────────────────────────

export const FleetInstanceNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as FleetInstanceNodeData;
  return (
    <div className="px-3 py-2 bg-theme-background-secondary border border-theme rounded-lg w-[180px]">
      <TopHandle />
      <BottomHandle />
      <div className="flex items-center gap-1.5">
        <Cpu className="w-3.5 h-3.5 text-theme-secondary shrink-0" />
        <span className="text-xs text-theme-primary truncate" title={d.label}>
          {d.label}
        </span>
        <span
          className={`w-2 h-2 rounded-full shrink-0 ml-auto ${instanceStatusColor(d.status)}`}
          title={d.status}
        />
      </div>
      <div className="text-[10px] text-theme-secondary mt-0.5 flex items-center gap-1">
        <span>{d.variety}</span>
        {d.address && <span className="font-mono truncate">{d.address}</span>}
      </div>
      {d.boot_image_drifted && (
        <div className="flex items-center gap-1 text-[9px] text-theme-warning-fg mt-0.5">
          <AlertTriangle className="w-3 h-3" />
          boot image drift
        </div>
      )}
    </div>
  );
};

// ─── SDWAN network ──────────────────────────────────────────────────

export const FleetNetworkNode: React.FC<NodeProps> = ({ data }) => {
  const d = data as unknown as FleetNetworkNodeData;
  return (
    <div className="px-3 py-2 bg-theme-surface border border-theme rounded-lg shadow-sm w-[190px]">
      <TopHandle />
      <div className="flex items-center gap-2">
        <NetworkIcon className="w-4 h-4 text-theme-secondary shrink-0" />
        <span className="font-medium text-sm text-theme-primary truncate" title={d.label}>
          {d.label}
        </span>
      </div>
      {d.cidr && <div className="text-[10px] text-theme-secondary mt-1 font-mono">{d.cidr}</div>}
      <div className="text-[10px] text-theme-secondary mt-0.5">
        {d.member_count} member{d.member_count === 1 ? '' : 's'}
        {d.status ? ` · ${d.status}` : ''}
      </div>
    </div>
  );
};

// ─── Status → theme token ───────────────────────────────────────────
//
// -solid variants render at full saturation; the bare names are tinted
// ~10-15% alpha backgrounds meant for card fills, which are invisible at
// the 8px a status dot renders at. Same rule as SystemTopology.

export function nodeHealthColor(health: FleetNodeHealth): string {
  switch (health) {
    case 'running':
      return 'bg-theme-success-solid';
    case 'partial':
      return 'bg-theme-warning-solid';
    case 'idle':
      return 'bg-theme-info-solid';
    case 'disabled':
      return 'bg-theme-error-solid';
    default:
      return 'bg-theme-background-tertiary';
  }
}

export function nodeHealthLabel(health: FleetNodeHealth): string {
  switch (health) {
    case 'running':
      return 'All instances running';
    case 'partial':
      return 'Some instances running';
    case 'idle':
      return 'No instances running';
    case 'disabled':
      return 'Node disabled';
    default:
      return 'No instances';
  }
}

export function instanceStatusColor(status: string): string {
  switch (status) {
    case 'running':
      return 'bg-theme-success-solid';
    case 'pending':
    case 'provisioning':
    case 'starting':
    case 'rebooting':
      return 'bg-theme-info-solid';
    case 'stopping':
      return 'bg-theme-warning-solid';
    case 'error':
      return 'bg-theme-error-solid';
    case 'stopped':
    case 'terminated':
    default:
      return 'bg-theme-background-tertiary';
  }
}

export const FLEET_NODE_TYPES = {
  'fleet-group': FleetGroupNode,
  'fleet-node': FleetNodeCard,
  'fleet-instance': FleetInstanceNode,
  'fleet-network': FleetNetworkNode,
} as const;
