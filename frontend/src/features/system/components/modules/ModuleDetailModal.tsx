import React, { useState, useEffect, useCallback } from 'react';
import {
  X,
  Package,
  Settings,
  FileCode,
  GitBranch,
  Globe,
  Lock,
  CheckCircle,
  XCircle,
  Plus,
  Trash2,
  ArrowRight,
  ShieldCheck
} from 'lucide-react';
import { ConsentBudgetEditor } from './ConsentBudgetEditor';
import { CanaryMarker } from './CanaryMarker';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule } from '@system/features/system/types/system.types';

interface ModuleDetailModalProps {
  moduleId: string | null;
  isOpen: boolean;
  onClose: () => void;
  onEdit?: (module: SystemNodeModule) => void;
}

type TabId = 'info' | 'specs' | 'dependencies' | 'autonomy';

const varietyLabels: Record<string, string> = {
  config: 'Config',
  instance: 'Instance',
  subscription: 'Subscription'
};

const varietyColors: Record<string, 'info' | 'success' | 'warning'> = {
  config: 'info',
  instance: 'success',
  subscription: 'warning'
};

/**
 * ModuleDetailModal - Modal for viewing module details with tabs
 */
export const ModuleDetailModal: React.FC<ModuleDetailModalProps> = ({
  moduleId,
  isOpen,
  onClose,
  onEdit
}) => {
  const { addNotification } = useNotifications();
  const { hasPermission } = usePermissions();

  const canManageDependencies = hasPermission('system.modules.update');

  const [module, setModule] = useState<SystemNodeModule | null>(null);
  const [loading, setLoading] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>('info');

  // Dependencies state
  const [dependencies, setDependencies] = useState<SystemNodeModule[]>([]);
  const [loadingDependencies, setLoadingDependencies] = useState(false);
  const [availableModules, setAvailableModules] = useState<SystemNodeModule[]>([]);
  const [showAddDependencyModal, setShowAddDependencyModal] = useState(false);
  const [selectedDependency, setSelectedDependency] = useState<string>('');
  const [addingDependency, setAddingDependency] = useState(false);
  const [removingDependency, setRemovingDependency] = useState<string | null>(null);

  // Fetch module details
  useEffect(() => {
    if (isOpen && moduleId) {
      setLoading(true);
      setActiveTab('info');

      systemApi.getModule(moduleId)
        .then(data => {
          setModule(data);
        })
        .catch(() => {
          setModule(null);
        })
        .finally(() => {
          setLoading(false);
        });
    }
  }, [isOpen, moduleId]);

  // Fetch dependencies when dependencies tab is active
  useEffect(() => {
    if (isOpen && moduleId && activeTab === 'dependencies') {
      setLoadingDependencies(true);
      systemApi.getModuleDependencies(moduleId)
        .then(deps => {
          setDependencies(deps);
        })
        .catch(() => {
          setDependencies([]);
        })
        .finally(() => {
          setLoadingDependencies(false);
        });
    }
  }, [isOpen, moduleId, activeTab]);

  // Fetch available modules when add modal opens
  useEffect(() => {
    if (showAddDependencyModal && moduleId) {
      systemApi.getModules()
        .then(result => {
          // Filter out current module and existing dependencies
          const depIds = new Set(dependencies.map(d => d.id));
          const filtered = result.modules.filter(m => m.id !== moduleId && !depIds.has(m.id));
          setAvailableModules(filtered);
        })
        .catch(() => {
          setAvailableModules([]);
        });
    }
  }, [showAddDependencyModal, moduleId, dependencies]);

  // Add dependency handler
  const handleAddDependency = useCallback(async () => {
    if (!moduleId || !selectedDependency) return;

    setAddingDependency(true);
    try {
      await systemApi.addModuleDependency(moduleId, selectedDependency);
      addNotification({
        type: 'success',
        message: 'Dependency added successfully'
      });
      // Refresh dependencies
      const deps = await systemApi.getModuleDependencies(moduleId);
      setDependencies(deps);
      setShowAddDependencyModal(false);
      setSelectedDependency('');
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to add dependency: ${errorMessage}`
      });
    } finally {
      setAddingDependency(false);
    }
  }, [moduleId, selectedDependency, addNotification]);

  // Remove dependency handler
  const handleRemoveDependency = useCallback(async (dependencyId: string) => {
    if (!moduleId) return;

    setRemovingDependency(dependencyId);
    try {
      await systemApi.removeModuleDependency(moduleId, dependencyId);
      addNotification({
        type: 'success',
        message: 'Dependency removed successfully'
      });
      setDependencies(prev => prev.filter(d => d.id !== dependencyId));
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'An error occurred';
      addNotification({
        type: 'error',
        message: `Failed to remove dependency: ${errorMessage}`
      });
    } finally {
      setRemovingDependency(null);
    }
  }, [moduleId, addNotification]);

  if (!isOpen) return null;

  const tabs = [
    { id: 'info' as const, label: 'Information', icon: Package },
    { id: 'specs' as const, label: 'Specifications', icon: FileCode },
    { id: 'dependencies' as const, label: 'Dependencies', icon: GitBranch },
    { id: 'autonomy' as const, label: 'Autonomy', icon: ShieldCheck }
  ];

  const renderAutonomyTab = () => {
    if (!module) return null;
    // Autonomy controls: per-module consent budget. Hidden behind a tab
    // so non-operator viewers see nothing about budget enforcement and
    // operators with system.modules.update permission can configure.
    return (
      <div className="space-y-6">
        <ConsentBudgetEditor
          module={module as unknown as Parameters<typeof ConsentBudgetEditor>[0]['module']}
          onUpdated={(updated) => setModule(updated as unknown as SystemNodeModule)}
        />
        <CanaryMarker
          module={module}
          onUpdated={(updated) => setModule(updated)}
        />
        <div className="text-xs text-theme-muted">
          The consent budget is a per-module ceiling on autonomous decisions
          (drift remediation, module reassignment, cert rotation) that
          FleetAutonomyService can take in a 24-hour window. When exhausted,
          decisions force require_approval regardless of policy.
        </div>
      </div>
    );
  };

  const renderInfoTab = () => {
    if (!module) return null;

    return (
      <div className="space-y-6">
        {/* Basic Info */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-6">
          <div className="space-y-4">
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Name</label>
              <p className="text-theme-primary font-medium">{module.name}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Description</label>
              <p className="text-theme-primary">{module.description || '—'}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Category</label>
              <p className="text-theme-primary">{module.category_name || '—'}</p>
            </div>
          </div>
          <div className="space-y-4">
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Type</label>
              <Badge variant={varietyColors[module.variety]}>
                {varietyLabels[module.variety] || module.variety}
              </Badge>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Platform</label>
              <p className="text-theme-primary">{module.node_platform_name || '—'}</p>
            </div>
            <div>
              <label className="block text-sm text-theme-secondary mb-1">Priority</label>
              <p className="text-theme-primary">{module.priority}</p>
            </div>
          </div>
        </div>

        {/* Status Badges */}
        <div className="flex flex-wrap gap-4 pt-4 border-t border-theme">
          <div className="flex items-center gap-2">
            {module.enabled ? (
              <CheckCircle className="w-5 h-5 text-theme-success" />
            ) : (
              <XCircle className="w-5 h-5 text-theme-error" />
            )}
            <span className="text-theme-primary">
              {module.enabled ? 'Enabled' : 'Disabled'}
            </span>
          </div>
          <div className="flex items-center gap-2">
            {module.public ? (
              <Globe className="w-5 h-5 text-theme-info" />
            ) : (
              <Lock className="w-5 h-5 text-theme-secondary" />
            )}
            <span className="text-theme-primary">
              {module.public ? 'Public' : 'Private'}
            </span>
          </div>
        </div>

        {/* Timestamps */}
        <div className="grid grid-cols-2 gap-4 pt-4 border-t border-theme text-sm">
          <div>
            <span className="text-theme-secondary">Created:</span>
            <span className="ml-2 text-theme-primary">
              {module.created_at ? new Date(module.created_at).toLocaleString() : '—'}
            </span>
          </div>
          <div>
            <span className="text-theme-secondary">Updated:</span>
            <span className="ml-2 text-theme-primary">
              {module.updated_at ? new Date(module.updated_at).toLocaleString() : '—'}
            </span>
          </div>
        </div>
      </div>
    );
  };

  const renderSpecsTab = () => {
    if (!module) return null;

    // Each spec field arrives from the API as a `string[]` of base64-encoded
    // glob lines, paired with a pre-decoded `_text` companion. Use the
    // _text companion for display — it's the same source the edit form uses.
    const specSections: Array<{
      key: string;
      title: string;
      icon: React.ReactNode;
      help: string;
      text?: string;
      tone?: 'default' | 'protected' | 'mask';
    }> = [
      {
        key: 'file_spec',
        title: module.dependant
          ? `File spec (inherited from ${module.parent_module_name ?? 'parent'}.dependency_spec)`
          : 'File spec',
        icon: <FileCode className="w-4 h-4 text-theme-info" />,
        help: module.dependant
          ? `This is a dependant child module. Its file_spec is read-through from its parent's dependency_spec at runtime — to change what this dependant ships, edit ${module.parent_module_name ?? 'the parent'}'s dependency_spec instead.`
          : 'Paths this module owns and ships in its blob.',
        text: module.file_spec_text,
      },
      {
        key: 'protected_spec',
        title: 'Protected spec',
        icon: <ShieldCheck className="w-4 h-4 text-theme-info" />,
        help: 'Paths this module claims as sensitive. The build pipeline folds these into every neighbor\'s effective_mask, so no other module ships them. Used for /etc/shadow, /etc/ssh/ssh_host_*_key, and other security-critical files.',
        text: module.protected_spec_text,
        tone: 'protected',
      },
      {
        key: 'mask',
        title: 'Mask (local exclude)',
        icon: <Settings className="w-4 h-4 text-theme-info" />,
        help: 'Paths to exclude from THIS module\'s blob during build (build cruft like /var/cache/apt/**). Local rsync filter; does not affect neighbors.',
        text: module.mask_text,
        tone: 'mask',
      },
      {
        key: 'package_spec',
        title: 'Package spec',
        icon: <Package className="w-4 h-4 text-theme-info" />,
        help: 'Debian packages installed into the build chroot.',
        text: module.package_spec_text,
      },
      {
        key: 'dependency_spec',
        title: 'Dependency spec (inherited by dependants)',
        icon: <GitBranch className="w-4 h-4 text-theme-info" />,
        help: 'The file-spec this module\'s dependant config / instance children inherit. When a child is created with this module as its parent_module, the child\'s file_spec returns this value transparently. Subscription-variety bases populate it; leaf modules with no dependants leave it empty.',
        text: module.dependency_spec_text,
      },
    ];

    const hasConfig = module.config && Object.keys(module.config).length > 0;

    return (
      <div className="space-y-6">
        {specSections.map(section => {
          const lines = (section.text ?? '')
            .split(/\r?\n/)
            .map(l => l.trim())
            .filter(l => l.length > 0);
          const empty = lines.length === 0;
          const borderClass =
            section.tone === 'protected' ? 'border-theme-warning' :
            section.tone === 'mask' ? 'border-theme-info' :
            'border-theme';
          return (
            <div key={section.key}>
              <div className="flex items-center gap-2 mb-1">
                {section.icon}
                <h4 className="font-medium text-theme-primary">{section.title}</h4>
                {!empty && (
                  <Badge variant="default" size="xs">{lines.length}</Badge>
                )}
              </div>
              <p className="text-xs text-theme-secondary mb-2">{section.help}</p>
              {empty ? (
                <p className="text-theme-secondary text-sm italic">No entries.</p>
              ) : (
                <ul className={`bg-theme-background rounded-lg p-3 text-sm font-mono border ${borderClass} space-y-1 max-h-64 overflow-y-auto`}>
                  {lines.map((line, idx) => (
                    <li key={idx} className="text-theme-primary">{line}</li>
                  ))}
                </ul>
              )}
            </div>
          );
        })}

        {/* Lifecycle */}
        <div>
          <div className="flex items-center gap-2 mb-2">
            <Settings className="w-4 h-4 text-theme-info" />
            <h4 className="font-medium text-theme-primary">Lifecycle</h4>
          </div>
          <div className="bg-theme-background rounded-lg p-4 border border-theme grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
            <div>
              <div className="text-xs text-theme-secondary">init_start</div>
              <code className="text-theme-primary">{module.init_start || <span className="italic text-theme-tertiary">unset</span>}</code>
            </div>
            <div>
              <div className="text-xs text-theme-secondary">init_stop</div>
              <code className="text-theme-primary">{module.init_stop || <span className="italic text-theme-tertiary">unset</span>}</code>
            </div>
            <div>
              <div className="text-xs text-theme-secondary">init_restart</div>
              <code className="text-theme-primary">{module.init_restart || <span className="italic text-theme-tertiary">unset</span>}</code>
            </div>
            <div className="flex items-center gap-3">
              <Badge variant={module.reboot_required ? 'warning' : 'default'} size="xs">
                {module.reboot_required ? 'reboot required on attach/detach' : 'hot-swap allowed'}
              </Badge>
              <Badge variant={module.lock_spec ? 'danger' : 'default'} size="xs">
                <Lock className="w-3 h-3 inline mr-1" />
                {module.lock_spec ? 'spec locked' : 'spec mutable'}
              </Badge>
            </div>
          </div>
        </div>

        {/* Config (raw JSON — usually populated by manifest import) */}
        <div>
          <div className="flex items-center gap-2 mb-2">
            <Settings className="w-4 h-4 text-theme-info" />
            <h4 className="font-medium text-theme-primary">Configuration</h4>
          </div>
          <p className="text-xs text-theme-secondary mb-2">
            Free-form JSON. Populated by <code>ManifestImportService</code> with the
            module\'s security policy, declared skills, build hints, and any
            unknown fields under <code>manifest_extras</code>.
          </p>
          {hasConfig ? (
            <pre className="bg-theme-background rounded-lg p-4 text-sm text-theme-primary overflow-x-auto border border-theme max-h-72">
              {JSON.stringify(module.config, null, 2)}
            </pre>
          ) : (
            <p className="text-theme-secondary text-sm italic">No configuration set.</p>
          )}
        </div>
      </div>
    );
  };

  const renderDependenciesTab = () => {
    if (!module) return null;

    return (
      <div className="space-y-6">
        {/* Header with Add button */}
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2">
            <GitBranch className="w-5 h-5 text-theme-info" />
            <h4 className="font-medium text-theme-primary">Module Dependencies</h4>
          </div>
          {canManageDependencies && (
            <Button
              variant="primary"
              size="sm"
              onClick={() => setShowAddDependencyModal(true)}
            >
              <Plus className="w-4 h-4 mr-2" />
              Add Dependency
            </Button>
          )}
        </div>

        {/* Dependencies List */}
        {loadingDependencies ? (
          <div className="flex items-center justify-center py-8">
            <LoadingSpinner size="md" />
          </div>
        ) : dependencies.length > 0 ? (
          <div className="space-y-3">
            {dependencies.map(dep => (
              <div
                key={dep.id}
                className="flex items-center justify-between bg-theme-background rounded-lg p-4 border border-theme"
              >
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 rounded-lg bg-theme-surface flex items-center justify-center">
                    <Package className="w-5 h-5 text-theme-info" />
                  </div>
                  <div>
                    <h5 className="font-medium text-theme-primary">{dep.name}</h5>
                    <div className="flex items-center gap-2 mt-1">
                      <Badge variant={varietyColors[dep.variety]} size="xs">
                        {varietyLabels[dep.variety] || dep.variety}
                      </Badge>
                      {dep.node_platform_name && (
                        <span className="text-xs text-theme-tertiary">
                          {dep.node_platform_name}
                        </span>
                      )}
                    </div>
                  </div>
                </div>
                <div className="flex items-center gap-2">
                  <ArrowRight className="w-4 h-4 text-theme-tertiary" />
                  {canManageDependencies && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => handleRemoveDependency(dep.id)}
                      disabled={removingDependency === dep.id}
                      title="Remove dependency"
                      className="text-theme-error hover:text-theme-error"
                    >
                      {removingDependency === dep.id ? (
                        <LoadingSpinner size="sm" />
                      ) : (
                        <Trash2 className="w-4 h-4" />
                      )}
                    </Button>
                  )}
                </div>
              </div>
            ))}
          </div>
        ) : (
          <div className="text-center py-8">
            <GitBranch className="w-12 h-12 text-theme-tertiary mx-auto mb-4" />
            <p className="text-theme-secondary">No dependencies configured</p>
            <p className="text-sm text-theme-tertiary mt-1">
              This module operates independently
            </p>
          </div>
        )}

        {/* Dependents Count (modules that depend on this one) */}
        {module.dependents_count && module.dependents_count > 0 && (
          <div className="pt-4 border-t border-theme">
            <p className="text-sm text-theme-secondary">
              <strong>{module.dependents_count}</strong> other module{module.dependents_count !== 1 ? 's' : ''} depend{module.dependents_count === 1 ? 's' : ''} on this module
            </p>
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="fixed inset-0 z-50 overflow-y-auto">
      <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={onClose} />

      <div className="flex min-h-full items-center justify-center p-4">
        <div className="relative w-full max-w-3xl bg-theme-surface rounded-lg shadow-xl">
          {/* Header */}
          <div className="flex items-center justify-between p-4 border-b border-theme">
            <div className="flex items-center gap-3">
              <Package className="w-6 h-6 text-theme-info" />
              <div>
                <h2 className="text-lg font-semibold text-theme-primary">
                  {loading ? 'Loading...' : module?.name || 'Module Details'}
                </h2>
                {module && (
                  <p className="text-sm text-theme-secondary">
                    {varietyLabels[module.variety] || module.variety} Module
                  </p>
                )}
              </div>
            </div>
            <div className="flex items-center gap-2">
              {module && onEdit && (
                <Button variant="outline" size="sm" onClick={() => onEdit(module)}>
                  Edit
                </Button>
              )}
              <Button variant="ghost" size="sm" onClick={onClose}>
                <X className="w-5 h-5" />
              </Button>
            </div>
          </div>

          {/* Tabs */}
          <div className="border-b border-theme">
            <nav className="flex -mb-px">
              {tabs.map(tab => (
                <button
                  key={tab.id}
                  onClick={() => setActiveTab(tab.id)}
                  className={`flex items-center gap-2 px-6 py-3 text-sm font-medium border-b-2 transition-colors ${
                    activeTab === tab.id
                      ? 'border-theme-info text-theme-info'
                      : 'border-transparent text-theme-secondary hover:text-theme-primary hover:border-theme-tertiary'
                  }`}
                >
                  <tab.icon className="w-4 h-4" />
                  {tab.label}
                </button>
              ))}
            </nav>
          </div>

          {/* Content */}
          <div className="p-6 max-h-[60vh] overflow-y-auto">
            {loading ? (
              <div className="flex items-center justify-center py-12">
                <LoadingSpinner size="lg" />
              </div>
            ) : module ? (
              <>
                {activeTab === 'info' && renderInfoTab()}
                {activeTab === 'specs' && renderSpecsTab()}
                {activeTab === 'dependencies' && renderDependenciesTab()}
                {activeTab === 'autonomy' && renderAutonomyTab()}
              </>
            ) : (
              <div className="text-center py-12">
                <p className="text-theme-error">Failed to load module details</p>
              </div>
            )}
          </div>

          {/* Footer */}
          <div className="flex justify-end p-4 border-t border-theme">
            <Button variant="outline" onClick={onClose}>
              Close
            </Button>
          </div>
        </div>
      </div>

      {/* Add Dependency Modal */}
      {showAddDependencyModal && (
        <div className="fixed inset-0 z-[60] overflow-y-auto">
          <div
            className="fixed inset-0 bg-black/50 transition-opacity"
            onClick={() => {
              setShowAddDependencyModal(false);
              setSelectedDependency('');
            }}
          />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="flex items-center justify-between p-4 border-b border-theme">
                <div className="flex items-center gap-3">
                  <Plus className="w-6 h-6 text-theme-info" />
                  <h3 className="text-lg font-semibold text-theme-primary">
                    Add Dependency
                  </h3>
                </div>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => {
                    setShowAddDependencyModal(false);
                    setSelectedDependency('');
                  }}
                >
                  <X className="w-5 h-5" />
                </Button>
              </div>

              <div className="p-4">
                <label className="block text-sm font-medium text-theme-primary mb-2">
                  Select Module
                </label>
                {availableModules.length === 0 ? (
                  <p className="text-theme-secondary text-sm">
                    No available modules to add as dependencies
                  </p>
                ) : (
                  <select
                    value={selectedDependency}
                    onChange={(e) => setSelectedDependency(e.target.value)}
                    className="w-full px-3 py-2 rounded-lg border border-theme bg-theme-background text-theme-primary focus:outline-none focus:border-theme-focus"
                    disabled={addingDependency}
                  >
                    <option value="">Select a module...</option>
                    {availableModules.map(mod => (
                      <option key={mod.id} value={mod.id}>
                        {mod.name} ({varietyLabels[mod.variety] || mod.variety})
                      </option>
                    ))}
                  </select>
                )}
              </div>

              <div className="flex justify-end gap-3 p-4 border-t border-theme">
                <Button
                  variant="outline"
                  onClick={() => {
                    setShowAddDependencyModal(false);
                    setSelectedDependency('');
                  }}
                  disabled={addingDependency}
                >
                  Cancel
                </Button>
                <Button
                  variant="primary"
                  onClick={handleAddDependency}
                  disabled={!selectedDependency || addingDependency}
                >
                  {addingDependency ? (
                    <>
                      <LoadingSpinner size="sm" className="mr-2" />
                      Adding...
                    </>
                  ) : (
                    'Add Dependency'
                  )}
                </Button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default ModuleDetailModal;
