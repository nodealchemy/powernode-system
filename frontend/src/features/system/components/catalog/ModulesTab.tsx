import React, { useState, useCallback, useEffect } from 'react';
import { Button } from '@/shared/components/ui/Button';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { ModuleList, ModuleDetailModal, ModuleFormModal, ModuleCategoryFormModal } from '@system/features/system/components/modules';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule, SystemNodeModuleCategory } from '@system/features/system/types/system.types';

interface ModulesTabProps {
  // Two action callbacks — the hub renders both buttons in PageContainer.actions.
  onActionsReady?: (
    handle: { openCreate: () => void; openCreateCategory: () => void } | null
  ) => void;
}

export const ModulesTab: React.FC<ModulesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const { addNotification } = useNotifications();
  const canCreate = hasPermission('system.modules.create');
  const canDelete = hasPermission('system.modules.delete');

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [selectedModuleId, setSelectedModuleId] = useState<string | null>(null);
  const [editModule, setEditModule] = useState<SystemNodeModule | null>(null);
  const [moduleToDelete, setModuleToDelete] = useState<string | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);
  const [deleting, setDeleting] = useState(false);

  const [categories, setCategories] = useState<SystemNodeModuleCategory[]>([]);
  const [showCategoryFormModal, setShowCategoryFormModal] = useState(false);
  const [editCategory, setEditCategory] = useState<SystemNodeModuleCategory | null>(null);
  const [categoryToDelete, setCategoryToDelete] = useState<string | null>(null);
  const [showCategoryDeleteConfirm, setShowCategoryDeleteConfirm] = useState(false);
  const [deletingCategory, setDeletingCategory] = useState(false);

  const handleCreate = useCallback(() => { setEditModule(null); setShowFormModal(true); }, []);
  const handleCategoryCreate = useCallback(() => { setEditCategory(null); setShowCategoryFormModal(true); }, []);

  useEffect(() => {
    onActionsReady?.({ openCreate: handleCreate, openCreateCategory: handleCategoryCreate });
    return () => onActionsReady?.(null);
  }, [onActionsReady, handleCreate, handleCategoryCreate]);

  useEffect(() => {
    systemApi.getModuleCategories().then(setCategories).catch(() => { /* optional */ });
  }, [refreshKey]);

  const handleView = useCallback((m: SystemNodeModule) => { setSelectedModuleId(m.id); setShowDetailModal(true); }, []);
  const handleEdit = useCallback((m: SystemNodeModule) => { setEditModule(m); setShowFormModal(true); }, []);
  const handleEditFromDetail = useCallback((m: SystemNodeModule) => {
    setShowDetailModal(false); setSelectedModuleId(null); setEditModule(m); setShowFormModal(true);
  }, []);
  const handleDeleteClick = useCallback((id: string) => { setModuleToDelete(id); setShowDeleteConfirm(true); }, []);
  const handleDeleteConfirm = async () => {
    if (!moduleToDelete) return;
    setDeleting(true);
    try {
      await systemApi.deleteModule(moduleToDelete);
      addNotification({ type: 'success', message: 'Module deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete module: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeleting(false); setShowDeleteConfirm(false); setModuleToDelete(null);
    }
  };
  const handleModuleSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditModule(null); }, []);

  const handleCategoryEdit = useCallback((c: SystemNodeModuleCategory) => { setEditCategory(c); setShowCategoryFormModal(true); }, []);
  const handleCategoryDeleteClick = useCallback((id: string) => { setCategoryToDelete(id); setShowCategoryDeleteConfirm(true); }, []);
  const handleCategoryDeleteConfirm = async () => {
    if (!categoryToDelete) return;
    setDeletingCategory(true);
    try {
      await systemApi.deleteModuleCategory(categoryToDelete);
      addNotification({ type: 'success', message: 'Category deleted successfully' });
      setRefreshKey((k) => k + 1);
    } catch (error) {
      addNotification({ type: 'error', message: `Failed to delete category: ${error instanceof Error ? error.message : 'An error occurred'}` });
    } finally {
      setDeletingCategory(false); setShowCategoryDeleteConfirm(false); setCategoryToDelete(null);
    }
  };
  const handleCategorySaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditCategory(null); }, []);

  return (
    <>
      <ModuleList
        key={refreshKey}
        onView={handleView}
        onEdit={handleEdit}
        onDelete={canDelete ? handleDeleteClick : undefined}
        onCreate={canCreate ? handleCreate : undefined}
        onCategoryCreate={canCreate ? handleCategoryCreate : undefined}
        onCategoryEdit={handleCategoryEdit}
        onCategoryDelete={handleCategoryDeleteClick}
      />

      <ModuleDetailModal
        moduleId={selectedModuleId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedModuleId(null); }}
        onEdit={handleEditFromDetail}
      />

      <ModuleFormModal
        isOpen={showFormModal}
        onClose={() => { setShowFormModal(false); setEditModule(null); }}
        onModuleSaved={handleModuleSaved}
        editModule={editModule}
      />

      {showDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Module</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this module? This action cannot be undone.
                  Nodes using this module will need to be reconfigured.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowDeleteConfirm(false); setModuleToDelete(null); }}>Cancel</Button>
                  <Button variant="danger" onClick={handleDeleteConfirm} disabled={deleting}>
                    {deleting ? 'Deleting...' : 'Delete Module'}
                  </Button>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}

      <ModuleCategoryFormModal
        category={editCategory}
        categories={categories}
        isOpen={showCategoryFormModal}
        onClose={() => { setShowCategoryFormModal(false); setEditCategory(null); }}
        onCategorySaved={handleCategorySaved}
      />

      {showCategoryDeleteConfirm && (
        <div className="fixed inset-0 z-50 overflow-y-auto">
          <div className="fixed inset-0 bg-black/50 transition-opacity" onClick={() => setShowCategoryDeleteConfirm(false)} />
          <div className="flex min-h-full items-center justify-center p-4">
            <div className="relative w-full max-w-md bg-theme-surface rounded-lg shadow-xl">
              <div className="p-6">
                <h3 className="text-lg font-semibold text-theme-primary mb-2">Delete Category</h3>
                <p className="text-theme-secondary mb-6">
                  Are you sure you want to delete this category? This action cannot be undone.
                  Modules in this category will need to be reassigned.
                </p>
                <div className="flex justify-end gap-3">
                  <Button variant="outline" onClick={() => { setShowCategoryDeleteConfirm(false); setCategoryToDelete(null); }}>Cancel</Button>
                  <Button variant="danger" onClick={handleCategoryDeleteConfirm} disabled={deletingCategory}>
                    {deletingCategory ? 'Deleting...' : 'Delete Category'}
                  </Button>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
};
