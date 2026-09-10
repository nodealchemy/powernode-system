import React from 'react';
import { Cpu, Plus, Edit2, Trash2 } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import type { SystemProviderInstanceType } from '@system/features/system/types/system.types';

export interface ProviderInstanceTypesTabProps {
  instanceTypes: SystemProviderInstanceType[];
  instanceTypesLoading: boolean;
  instanceTypesTotal: number;
  hasCloudConnection: boolean;
  canManageInstanceTypes: boolean;
  canUpdateInstanceTypes: boolean;
  canDeleteInstanceTypes: boolean;
  onAddInstanceType: () => void;
  onEditInstanceType: (instanceType: SystemProviderInstanceType) => void;
  onDeleteInstanceType: (instanceType: SystemProviderInstanceType) => void;
}

export const ProviderInstanceTypesTab: React.FC<ProviderInstanceTypesTabProps> = ({
  instanceTypes,
  instanceTypesLoading,
  instanceTypesTotal,
  hasCloudConnection,
  canManageInstanceTypes,
  canUpdateInstanceTypes,
  canDeleteInstanceTypes,
  onAddInstanceType,
  onEditInstanceType,
  onDeleteInstanceType,
}) => (
  <div className="space-y-4">
    {hasCloudConnection && (
      <p className="text-xs text-theme-warning-fg bg-theme-background rounded-lg p-3 border border-theme">
        This provider has a cloud connection, so instance types are normally
        populated by Sync catalog. Writes here are a manual override.
      </p>
    )}

    {canManageInstanceTypes && (
      <div className="flex justify-end">
        <Button
          variant="primary"
          size="sm"
          onClick={onAddInstanceType}
          title={
            hasCloudConnection
              ? 'Add instance type (manual override)'
              : 'Add instance type'
          }
        >
          <Plus className="w-4 h-4 mr-2" />
          Add Instance Type
        </Button>
      </div>
    )}

    {instanceTypesLoading ? (
      <div className="flex justify-center py-12">
        <LoadingSpinner size="lg" />
      </div>
    ) : instanceTypes.length === 0 ? (
      <div className="text-center py-12">
        <Cpu className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
        <p className="text-theme-secondary">No instance types configured</p>
        <p className="text-sm text-theme-tertiary mt-1">
          Declare the shapes this provider can hand out
        </p>
      </div>
    ) : (
      <>
      {instanceTypesTotal > instanceTypes.length && (
        <p className="text-xs text-theme-warning-fg">
          Showing {instanceTypes.length} of {instanceTypesTotal} instance types —
          narrow the catalog or use the API for the rest.
        </p>
      )}
      {instanceTypes.map(instanceType => (
        <div
          key={instanceType.id}
          className="bg-theme-background rounded-lg p-4 border border-theme"
          data-testid={`instance-type-${instanceType.id}`}
        >
          <div className="flex items-start justify-between">
            <div>
              <h4 className="font-medium text-theme-primary">{instanceType.name}</h4>
              <p className="text-xs text-theme-tertiary font-mono mt-1">
                {instanceType.instance_type_code}
              </p>
              <p className="text-sm text-theme-secondary mt-1">
                {instanceType.vcpus ?? '—'} vCPU • {instanceType.memory_mb ?? '—'} MB
                {' • '}
                {instanceType.storage_gb ?? '—'} GB
              </p>
            </div>
            <div className="flex items-center gap-2">
              <Badge variant={instanceType.enabled ? 'success' : 'secondary'} size="xs">
                {instanceType.enabled ? 'Enabled' : 'Disabled'}
              </Badge>
              {canUpdateInstanceTypes && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onEditInstanceType(instanceType)}
                  title="Edit instance type"
                >
                  <Edit2 className="w-4 h-4" />
                </Button>
              )}
              {canDeleteInstanceTypes && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => onDeleteInstanceType(instanceType)}
                  title="Delete instance type"
                  className="text-theme-error-fg hover:text-theme-error-fg"
                >
                  <Trash2 className="w-4 h-4" />
                </Button>
              )}
            </div>
          </div>
          {instanceType.description && (
            <p className="text-sm text-theme-secondary mt-2">{instanceType.description}</p>
          )}
        </div>
      ))}
      </>
    )}
  </div>
);

export default ProviderInstanceTypesTab;
