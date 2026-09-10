import React from 'react';
import { Activity } from 'lucide-react';
import { EntityLink } from '@/shared/components/entity';
import { resolveOperableType } from '@system/features/system/entityRegistry';
import type { SystemTask } from '@system/features/system/types/system.types';
import { getOperationStatusBadge } from './nodeDetailHelpers';

export interface NodeOperationsTabProps {
  operations: SystemTask[];
}

export const NodeOperationsTab: React.FC<NodeOperationsTabProps> = ({ operations }) => (
  <div className="space-y-4">
    {operations.length === 0 ? (
      <div className="text-center py-8 text-theme-secondary">
        <Activity className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No operations found</p>
      </div>
    ) : (
      <div className="space-y-3">
        {operations.map(operation => {
          const operableType = operation.operable_type
            ? resolveOperableType(operation.operable_type)
            : undefined;
          return (
          <div
            key={operation.id}
            className="bg-theme-surface-hover rounded-lg p-4 border border-theme"
          >
            <div className="flex items-start justify-between">
              <div className="flex-1">
                <div className="flex items-center gap-3">
                  <h4 className="font-medium text-theme-primary">{operation.command}</h4>
                  {getOperationStatusBadge(operation.status)}
                </div>
                {operation.description && (
                  <p className="text-sm text-theme-secondary mt-1">{operation.description}</p>
                )}
                {/* Progress bar for running operations */}
                {operation.status === 'running' && (
                  <div className="mt-2">
                    <div className="flex items-center justify-between text-xs text-theme-secondary mb-1">
                      <span>Progress</span>
                      <span>{operation.progress}%</span>
                    </div>
                    <div className="w-full bg-theme-background-secondary rounded-full h-2">
                      <div
                        className="bg-theme-interactive-primary h-2 rounded-full transition-all duration-300"
                        style={{ width: `${operation.progress}%` }}
                      />
                    </div>
                  </div>
                )}
                {/* Error message */}
                {operation.status === 'failed' && operation.error_message && (
                  <p className="text-sm text-theme-danger-fg mt-2">{operation.error_message}</p>
                )}
                <div className="flex items-center gap-4 mt-2 text-xs text-theme-secondary">
                  {operation.started_at && (
                    <span>Started: {new Date(operation.started_at).toLocaleString()}</span>
                  )}
                  {operation.completed_at && (
                    <span>Completed: {new Date(operation.completed_at).toLocaleString()}</span>
                  )}
                </div>
                {operation.operable_id && operation.operable_type && (
                  <div className="flex items-center gap-2 mt-2 text-xs text-theme-secondary">
                    <span>Target:</span>
                    {operableType ? (
                      <EntityLink
                        type={operableType}
                        id={operation.operable_id}
                        label={operation.operable_type}
                        className="text-xs"
                      />
                    ) : (
                      <span className="text-theme-primary">{operation.operable_type}</span>
                    )}
                  </div>
                )}
              </div>
            </div>
          </div>
          );
        })}
      </div>
    )}
  </div>
);

export default NodeOperationsTab;
