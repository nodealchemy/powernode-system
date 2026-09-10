import React from 'react';
import { Copy, Check, Globe, Shield, Cpu, Clock, Settings } from 'lucide-react';
import { EntityLink } from '@/shared/components/entity';
import type { SystemNode, SystemNodeInstance } from '@system/features/system/types/system.types';
import { getStatusBadge } from './nodeDetailHelpers';

export interface NodeInfoTabProps {
  node: SystemNode | null;
  instances: SystemNodeInstance[];
  copiedField: string | null;
  onCopy: (text: string, field: string) => void;
}

export const NodeInfoTab: React.FC<NodeInfoTabProps> = ({ node, instances, copiedField, onCopy }) => (
  <div className="space-y-6">
    {/* Basic Info */}
    <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
      <div className="space-y-4">
        <div>
          <label className="text-sm text-theme-secondary">Name</label>
          <p className="text-theme-primary font-medium">{node?.name}</p>
        </div>
        <div>
          <label className="text-sm text-theme-secondary">Description</label>
          <p className="text-theme-primary">{node?.description || '-'}</p>
        </div>
        <div>
          <label className="text-sm text-theme-secondary">Status</label>
          <div className="mt-1">{getStatusBadge(node?.status, node?.enabled)}</div>
        </div>
        <div>
          <label className="text-sm text-theme-secondary">Template</label>
          {node?.node_template_id ? (
            <p>
              <EntityLink
                type="node_template"
                id={node.node_template_id}
                label={node.node_template_name || node.node_template_id}
              />
            </p>
          ) : (
            <p className="text-theme-primary">{node?.node_template_name || '-'}</p>
          )}
        </div>
      </div>

      <div className="space-y-4">
        {node?.public_address && (
          <div>
            <label className="text-sm text-theme-secondary flex items-center gap-2">
              <Globe className="w-4 h-4" />
              Public Address
            </label>
            <div className="flex items-center gap-2 mt-1">
              <code className="text-theme-primary bg-theme-surface-hover px-2 py-1 rounded font-mono text-sm">
                {node.public_address}
              </code>
              <button
                onClick={() => onCopy(node.public_address!, 'address')}
                className="p-1 text-theme-secondary hover:text-theme-primary rounded"
                title="Copy address"
              >
                {copiedField === 'address' ? <Check className="w-4 h-4 text-theme-success-fg" /> : <Copy className="w-4 h-4" />}
              </button>
            </div>
          </div>
        )}
        <div>
          <label className="text-sm text-theme-secondary flex items-center gap-2">
            <Shield className="w-4 h-4" />
            Allocate Public IP
          </label>
          <p className="text-theme-primary">{node?.allocate_public_ip ? 'Yes' : 'No'}</p>
        </div>
        <div>
          <label className="text-sm text-theme-secondary flex items-center gap-2">
            <Cpu className="w-4 h-4" />
            Instances
          </label>
          <p className="text-theme-primary">{node?.instance_count ?? instances.length}</p>
        </div>
        <div>
          <label className="text-sm text-theme-secondary flex items-center gap-2">
            <Clock className="w-4 h-4" />
            Created
          </label>
          <p className="text-theme-primary">
            {node?.created_at ? new Date(node.created_at).toLocaleString() : '-'}
          </p>
        </div>
      </div>
    </div>

    {/* Configuration */}
    {node?.config && Object.keys(node.config).length > 0 && (
      <div>
        <label className="text-sm text-theme-secondary flex items-center gap-2 mb-2">
          <Settings className="w-4 h-4" />
          Configuration
        </label>
        <pre className="bg-theme-surface-hover rounded-lg p-4 text-sm text-theme-primary overflow-x-auto">
          {JSON.stringify(node.config, null, 2)}
        </pre>
      </div>
    )}
  </div>
);

export default NodeInfoTab;
