import React from 'react';
import { LayoutTemplate } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { TemplateComposerPage as TemplateComposerComponent } from '@system/features/system/components/templates/composer/TemplateComposerPage';

// Page-level wrapper for the visual Template Composer (M-FE-1).
const TemplateComposerPageWrapper: React.FC = () => {
  const { hasPermission } = usePermissions();

  if (!hasPermission('system.templates.update')) {
    return (
      <PageContainer
        title="Template Composer"
        icon={<LayoutTemplate size={20} />}
      >
        <div className="p-6 text-sm text-theme-muted">
          You don't have permission to compose templates.
          Required: <code>system.templates.update</code>
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Template Composer"
      icon={<LayoutTemplate size={20} />}
      noPadding
    >
      <TemplateComposerComponent />
    </PageContainer>
  );
};

export default TemplateComposerPageWrapper;
export { TemplateComposerPageWrapper as TemplateComposerPage };
