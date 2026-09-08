import React, { useCallback, useEffect, useState } from 'react';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { ModuleList, ModuleDetailModal, ModuleFormModal, ModuleCategoryFormModal } from '@system/features/system/components/modules';
import { systemApi } from '@system/features/system/services/systemApi';
import { useCrudTab } from '@system/features/system/hooks/useCrudTab';
import type { SystemNodeModule, SystemNodeModuleCategory } from '@system/features/system/types/system.types';

interface ModulesTabProps {
  // Two action callbacks — the hub renders both buttons in PageContainer.actions.
  onActionsReady?: (
    handle: { openCreate: () => void; openCreateCategory: () => void } | null
  ) => void;
}

export const ModulesTab: React.FC<ModulesTabProps> = ({ onActionsReady }) => {
  const { hasPermission } = usePermissions();
  const canCreate = hasPermission('system.modules.create');
  const canDelete = hasPermission('system.modules.delete');

  // Detail-modal state stays local: the hook owns the FORM, not the read view.
  const [showDetailModal, setShowDetailModal] = useState(false);
  const [selectedModuleId, setSelectedModuleId] = useState<string | null>(null);
  const [categories, setCategories] = useState<SystemNodeModuleCategory[]>([]);

  // Two entities, two CRUD flows. Neither passes onActionsReady: this tab
  // publishes a two-button handle, so the effect stays here rather than being
  // owned by one of the hooks.
  const moduleCrud = useCrudTab<SystemNodeModule>({
    entityLabel: 'Module',
    deleteMessage:
      'Are you sure you want to delete this module? This action cannot be undone. Nodes using this module will need to be reconfigured.',
    deleteFn: (id) => systemApi.deleteModule(id),
  });

  const categoryCrud = useCrudTab<SystemNodeModuleCategory>({
    entityLabel: 'Category',
    deleteMessage:
      'Are you sure you want to delete this category? This action cannot be undone. Modules in this category will need to be reassigned.',
    deleteFn: (id) => systemApi.deleteModuleCategory(id),
  });

  // One refresh signal, as before: a category change has always remounted the
  // module list and refetched the categories, because a module row shows its
  // category. Summing the two counters keeps that — the sum changes whenever
  // either side increments.
  const refreshKey = moduleCrud.refreshKey + categoryCrud.refreshKey;

  useEffect(() => {
    onActionsReady?.({
      openCreate: moduleCrud.handleCreate,
      openCreateCategory: categoryCrud.handleCreate,
    });
    return () => onActionsReady?.(null);
  }, [onActionsReady, moduleCrud.handleCreate, categoryCrud.handleCreate]);

  useEffect(() => {
    systemApi.getModuleCategories().then(setCategories).catch(() => { /* optional */ });
  }, [refreshKey]);

  const handleView = useCallback((m: SystemNodeModule) => {
    setSelectedModuleId(m.id);
    setShowDetailModal(true);
  }, []);
  // Depend on the CALLBACK, not the hook result: the result is a fresh object
  // literal every render, so [moduleCrud] would make this unstable.
  const { handleEdit: openModuleForm } = moduleCrud;
  const handleEditFromDetail = useCallback(
    (m: SystemNodeModule) => {
      setShowDetailModal(false);
      setSelectedModuleId(null);
      openModuleForm(m);
    },
    [openModuleForm],
  );

  return (
    <>
      <ModuleList
        key={refreshKey}
        onView={handleView}
        onEdit={moduleCrud.handleEdit}
        onDelete={canDelete ? moduleCrud.handleDeleteClick : undefined}
        onCreate={canCreate ? moduleCrud.handleCreate : undefined}
        onCategoryCreate={canCreate ? categoryCrud.handleCreate : undefined}
        onCategoryEdit={categoryCrud.handleEdit}
        onCategoryDelete={categoryCrud.handleDeleteClick}
      />

      <ModuleDetailModal
        moduleId={selectedModuleId}
        isOpen={showDetailModal}
        onClose={() => { setShowDetailModal(false); setSelectedModuleId(null); }}
        onEdit={handleEditFromDetail}
      />

      <ModuleFormModal
        isOpen={moduleCrud.showFormModal}
        onClose={moduleCrud.closeForm}
        onModuleSaved={moduleCrud.handleSaved}
        editModule={moduleCrud.editEntity}
      />

      <ModuleCategoryFormModal
        category={categoryCrud.editEntity}
        categories={categories}
        isOpen={categoryCrud.showFormModal}
        onClose={categoryCrud.closeForm}
        onCategorySaved={categoryCrud.handleSaved}
      />

      {moduleCrud.ConfirmationDialog}
      {categoryCrud.ConfirmationDialog}
    </>
  );
};
