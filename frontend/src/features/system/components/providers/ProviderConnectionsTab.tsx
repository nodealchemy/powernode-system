import React from 'react';
import { Server, Plus, Edit2, Trash2, RefreshCw, DownloadCloud } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { EntityLink } from '@/shared/components/entity';
import type { SystemProviderConnection } from '@system/features/system/types/system.types';

export interface ProviderConnectionsTabProps {
  connections: SystemProviderConnection[];
  canManageConnections: boolean;
  canDeleteConnections: boolean;
  canTestConnections: boolean;
  canSyncCatalog: boolean;
  testingConnection: string | null;
  syncingCatalog: string | null;
  onAddConnection: () => void;
  onEditConnection: (connection: SystemProviderConnection) => void;
  onDeleteRequest: (connection: SystemProviderConnection) => void;
  onTestConnection: (connection: SystemProviderConnection) => void;
  onSyncCatalog: (connection: SystemProviderConnection) => void;
}

export const ProviderConnectionsTab: React.FC<ProviderConnectionsTabProps> = ({
  connections,
  canManageConnections,
  canDeleteConnections,
  canTestConnections,
  canSyncCatalog,
  testingConnection,
  syncingCatalog,
  onAddConnection,
  onEditConnection,
  onDeleteRequest,
  onTestConnection,
  onSyncCatalog,
}) => (
  <div className="space-y-4">
    {/* Header with Add button */}
    {canManageConnections && (
      <div className="flex justify-end">
        <Button variant="primary" size="sm" onClick={onAddConnection}>
          <Plus className="w-4 h-4 mr-2" />
          Add Connection
        </Button>
      </div>
    )}

    {connections.length === 0 ? (
      <div className="text-center py-12">
        <Server className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
        <p className="text-theme-secondary">No connections configured</p>
        <p className="text-sm text-theme-tertiary mt-1">
          Add connections to authenticate with this provider
        </p>
      </div>
    ) : (
      connections.map(connection => (
        <div
          key={connection.id}
          className="bg-theme-background rounded-lg p-4 border border-theme"
        >
          <div className="flex items-start justify-between mb-2">
            <div>
              <h4 className="font-medium text-theme-primary">{connection.name}</h4>
              {connection.endpoint_url && (
                <p className="text-xs text-theme-tertiary font-mono mt-1">
                  {connection.endpoint_url}
                </p>
              )}
              {connection.provider_id && (
                <p className="text-xs text-theme-secondary mt-1">
                  Provider:{' '}
                  <EntityLink
                    type="provider"
                    id={connection.provider_id}
                    label={connection.provider_name || connection.provider_id}
                    className="text-xs"
                  />
                </p>
              )}
            </div>
            <div className="flex items-center gap-2">
              <Badge variant="success" size="xs">Active</Badge>
              {canTestConnections && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onTestConnection(connection)}
                  disabled={testingConnection === connection.id}
                  title="Test connection"
                >
                  {testingConnection === connection.id ? (
                    <RefreshCw className="w-4 h-4 animate-spin" />
                  ) : (
                    <RefreshCw className="w-4 h-4" />
                  )}
                </Button>
              )}
              {canSyncCatalog && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onSyncCatalog(connection)}
                  disabled={syncingCatalog === connection.id}
                  title="Sync catalog"
                >
                  <DownloadCloud
                    className={`w-4 h-4 ${syncingCatalog === connection.id ? 'animate-pulse' : ''}`}
                  />
                </Button>
              )}
              {canManageConnections && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onEditConnection(connection)}
                  title="Edit connection"
                >
                  <Edit2 className="w-4 h-4" />
                </Button>
              )}
              {canDeleteConnections && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onDeleteRequest(connection)}
                  title="Delete connection"
                  className="text-theme-error-fg hover:text-theme-error-fg"
                >
                  <Trash2 className="w-4 h-4" />
                </Button>
              )}
            </div>
          </div>
          {connection.description && (
            <p className="text-sm text-theme-secondary mt-2">{connection.description}</p>
          )}
        </div>
      ))
    )}
  </div>
);

export default ProviderConnectionsTab;
