import React, { useState, useCallback, useEffect } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { useConfirmation } from '@/shared/components/ui/ConfirmationModal';
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
  const { confirm, ConfirmationDialog } = useConfirmation();

  const [showFormModal, setShowFormModal] = useState(false);
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedModuleId, setSelectedModuleId] = useState<string | null>(null);
  const [editModule, setEditModule] = useState<SystemNodeModule | null>(null);
  const [refreshKey, setRefreshKey] = useState(0);

  const [categories, setCategories] = useState<SystemNodeModuleCategory[]>([]);
  const [showCategoryFormModal, setShowCategoryFormModal] = useState(false);
  const [editCategory, setEditCategory] = useState<SystemNodeModuleCategory | null>(null);

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
  const handleDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Module',
      message: 'Are you sure you want to delete this module? This action cannot be undone. Nodes using this module will need to be reconfigured.',
      confirmLabel: 'Delete Module',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteModule(id);
          addNotification({ type: 'success', message: 'Module deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete module: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
  const handleModuleSaved = useCallback(() => { setRefreshKey((k) => k + 1); setEditModule(null); }, []);

  const handleCategoryEdit = useCallback((c: SystemNodeModuleCategory) => { setEditCategory(c); setShowCategoryFormModal(true); }, []);
  const handleCategoryDeleteClick = useCallback((id: string) => {
    confirm({
      title: 'Delete Category',
      message: 'Are you sure you want to delete this category? This action cannot be undone. Modules in this category will need to be reassigned.',
      confirmLabel: 'Delete Category',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await systemApi.deleteModuleCategory(id);
          addNotification({ type: 'success', message: 'Category deleted successfully' });
          setRefreshKey((k) => k + 1);
        } catch (error) {
          addNotification({ type: 'error', message: `Failed to delete category: ${error instanceof Error ? error.message : 'An error occurred'}` });
        }
      }
    });
  }, [confirm, addNotification]);
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

      <ModuleCategoryFormModal
        category={editCategory}
        categories={categories}
        isOpen={showCategoryFormModal}
        onClose={() => { setShowCategoryFormModal(false); setEditCategory(null); }}
        onCategorySaved={handleCategorySaved}
      />

      {ConfirmationDialog}
    </>
  );
};
