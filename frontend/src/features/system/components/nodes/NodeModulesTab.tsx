import React from 'react';
import { Box, ChevronDown, ChevronRight } from 'lucide-react';
import { Badge } from '@/shared/components/ui/Badge';
import { Button } from '@/shared/components/ui/Button';
import { EntityLink } from '@/shared/components/entity';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

export interface NodeModulesTabProps {
  modules: SystemNodeModule[];
  expandedModuleIds: Set<string>;
  onToggleExpand: (id: string) => void;
  canUpdateModules: boolean;
  togglingAssignmentId: string | null;
  onToggleAssignment: (module: SystemNodeModule) => void;
}

export const NodeModulesTab: React.FC<NodeModulesTabProps> = ({
  modules,
  expandedModuleIds,
  onToggleExpand,
  canUpdateModules,
  togglingAssignmentId,
  onToggleAssignment,
}) => (
  <div className="space-y-4">
    {modules.length === 0 ? (
      <div className="text-center py-8 text-theme-secondary">
        <Box className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No modules assigned</p>
      </div>
    ) : (
      <div className="space-y-2">
        {modules.map(module => {
          const expanded = expandedModuleIds.has(module.id);
          const v = module.latest_version;
          return (
            <div
              key={module.id}
              className="bg-theme-surface-hover rounded-lg border border-theme overflow-hidden"
            >
              {/* Header — clickable */}
              <button
                type="button"
                onClick={() => onToggleExpand(module.id)}
                className="w-full flex items-center justify-between p-3 hover:bg-theme-surface transition-colors text-left"
              >
                <div className="flex items-center gap-3 min-w-0 flex-1">
                  {expanded ? <ChevronDown className="w-4 h-4 text-theme-secondary flex-shrink-0" /> : <ChevronRight className="w-4 h-4 text-theme-secondary flex-shrink-0" />}
                  <Box className="w-5 h-5 text-theme-secondary flex-shrink-0" />
                  <div className="min-w-0 flex-1">
                    <p className="font-medium text-theme-primary truncate">{module.name}</p>
                    <div className="flex items-center gap-2 mt-0.5 flex-wrap">
                      {module.category_name && (
                        <span className="text-xs text-theme-secondary">{module.category_name}</span>
                      )}
                      {module.parent_module_name && (
                        <span className="text-xs text-theme-tertiary">↳ inherits from {module.parent_module_name}</span>
                      )}
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-2 flex-shrink-0">
                  {v?.version_number && (
                    <Badge variant="outline" size="xs">v{v.version_number}</Badge>
                  )}
                  {v?.promotion_state && (
                    <Badge variant={v.promotion_state === 'live' ? 'success' : v.promotion_state === 'blessed' ? 'info' : 'secondary'} size="xs">
                      {v.promotion_state}
                    </Badge>
                  )}
                  <Badge variant="outline" size="xs">{module.variety}</Badge>
                  <Badge variant={module.enabled ? 'success' : 'secondary'} size="xs">
                    {module.enabled ? 'Enabled' : 'Disabled'}
                  </Badge>
                  {module.node_assignment && (
                    <Badge variant={module.node_assignment.enabled ? 'success' : 'warning'} size="xs">
                      {module.node_assignment.enabled ? 'On this node' : 'Off this node'}
                    </Badge>
                  )}
                </div>
              </button>
              {/* Expanded body */}
              {expanded && (
                <div className="px-4 pb-4 pt-2 border-t border-theme bg-theme-surface space-y-3">
                  {module.node_assignment && (
                    <div className="flex items-center justify-between gap-3 p-2 rounded-lg border border-theme">
                      <div className="text-sm min-w-0">
                        <p className="font-medium text-theme-primary">
                          {module.node_assignment.enabled ? 'Enabled on this node' : 'Disabled on this node'}
                        </p>
                        <p className="text-xs text-theme-tertiary">
                          Per-node toggle — the module stays attached; disabling keeps
                          priority/config but stops it composing into this node.
                        </p>
                      </div>
                      {canUpdateModules && (
                        <Button
                          size="sm"
                          variant={module.node_assignment.enabled ? 'ghost' : 'outline'}
                          disabled={togglingAssignmentId === module.node_assignment.id}
                          onClick={() => onToggleAssignment(module)}
                          title={module.node_assignment.enabled ? 'Disable on this node' : 'Enable on this node'}
                        >
                          {module.node_assignment.enabled ? 'Disable on this node' : 'Enable on this node'}
                        </Button>
                      )}
                    </div>
                  )}
                  {module.description && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Description</label>
                      <p className="text-sm text-theme-primary">{module.description}</p>
                    </div>
                  )}
                  <div className="grid grid-cols-2 gap-3 text-sm">
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Priority</label>
                      <p className="text-theme-primary font-mono">{module.priority}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Public</label>
                      <p className="text-theme-primary">{module.public ? 'Yes' : 'No'}</p>
                    </div>
                    {(module.node_platform_id || module.node_platform_name) && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Platform</label>
                        {module.node_platform_id ? (
                          <EntityLink
                            type="node_platform"
                            id={module.node_platform_id}
                            label={module.node_platform_name || module.node_platform_id}
                          />
                        ) : (
                          <p className="text-theme-primary">{module.node_platform_name}</p>
                        )}
                      </div>
                    )}
                    {(module.category_id || module.category_name) && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Category</label>
                        {module.category_id ? (
                          <EntityLink
                            type="node_module_category"
                            id={module.category_id}
                            label={module.category_name || module.category_id}
                          />
                        ) : (
                          <p className="text-theme-primary">{module.category_name}</p>
                        )}
                      </div>
                    )}
                    {(module.parent_module_id || module.parent_module_name) && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Parent Module</label>
                        {module.parent_module_id ? (
                          <EntityLink
                            type="node_module"
                            id={module.parent_module_id}
                            label={module.parent_module_name || module.parent_module_id}
                          />
                        ) : (
                          <p className="text-theme-primary">{module.parent_module_name}</p>
                        )}
                      </div>
                    )}
                    {module.copy_path_name && (
                      <div>
                        <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Copy Path</label>
                        <p className="text-theme-primary">{module.copy_path_name}</p>
                      </div>
                    )}
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Reboot Required</label>
                      <p className="text-theme-primary">{module.reboot_required ? 'Yes' : 'No'}</p>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Locked</label>
                      <p className="text-theme-primary">{module.lock_spec ? 'Yes' : 'No'}</p>
                    </div>
                  </div>

                  {/* Lifecycle hooks */}
                  {(module.init_start || module.init_stop || module.init_restart) && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Lifecycle Hooks</label>
                      <div className="space-y-1 text-sm font-mono">
                        {module.init_start && <div><span className="text-theme-tertiary">start:</span> <code className="text-theme-primary">{module.init_start}</code></div>}
                        {module.init_stop && <div><span className="text-theme-tertiary">stop:</span> <code className="text-theme-primary">{module.init_stop}</code></div>}
                        {module.init_restart && <div><span className="text-theme-tertiary">restart:</span> <code className="text-theme-primary">{module.init_restart}</code></div>}
                      </div>
                    </div>
                  )}

                  {/* Spec text fields — show only when populated */}
                  {module.file_spec_text && module.file_spec_text.length > 0 && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">File Spec</label>
                      <pre className="text-xs text-theme-primary bg-theme-surface-hover p-2 rounded border border-theme font-mono whitespace-pre-wrap">{module.file_spec_text}</pre>
                    </div>
                  )}
                  {module.package_spec_text && module.package_spec_text.length > 0 && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Package Spec</label>
                      <pre className="text-xs text-theme-primary bg-theme-surface-hover p-2 rounded border border-theme font-mono whitespace-pre-wrap">{module.package_spec_text}</pre>
                    </div>
                  )}
                  {module.dependency_spec_text && module.dependency_spec_text.length > 0 && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Dependency Spec</label>
                      <pre className="text-xs text-theme-primary bg-theme-surface-hover p-2 rounded border border-theme font-mono whitespace-pre-wrap">{module.dependency_spec_text}</pre>
                    </div>
                  )}
                  {module.protected_spec_text && module.protected_spec_text.length > 0 && (
                    <div>
                      <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Protected Spec</label>
                      <pre className="text-xs text-theme-primary bg-theme-surface-hover p-2 rounded border border-theme font-mono whitespace-pre-wrap">{module.protected_spec_text}</pre>
                    </div>
                  )}

                  {/* Version metadata */}
                  {v && (
                    <div className="grid grid-cols-2 gap-3 text-sm">
                      {v.version_number && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Version</label>
                          <p className="text-theme-primary font-mono">v{v.version_number}</p>
                        </div>
                      )}
                      {v.oci_digest && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">OCI Digest</label>
                          <p className="text-theme-primary font-mono text-xs truncate" title={v.oci_digest}>{v.oci_digest}</p>
                        </div>
                      )}
                      {v.blessed_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Blessed</label>
                          <p className="text-theme-primary text-xs">{new Date(v.blessed_at).toLocaleString()}</p>
                        </div>
                      )}
                      {v.live_at && (
                        <div>
                          <label className="block text-xs font-semibold text-theme-secondary uppercase tracking-wide mb-1">Live Since</label>
                          <p className="text-theme-primary text-xs">{new Date(v.live_at).toLocaleString()}</p>
                        </div>
                      )}
                    </div>
                  )}

                  {/* Counts row */}
                  <div className="flex items-center gap-4 pt-2 text-xs text-theme-secondary border-t border-theme">
                    <span><span className="font-semibold">{module.assignments_count ?? 0}</span> assignment(s)</span>
                    <span><span className="font-semibold">{module.dependencies_count ?? 0}</span> dependencies</span>
                    <span><span className="font-semibold">{module.dependents_count ?? 0}</span> dependents</span>
                    <span className="ml-auto">Updated {new Date(module.updated_at).toLocaleString()}</span>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>
    )}
  </div>
);

export default NodeModulesTab;
