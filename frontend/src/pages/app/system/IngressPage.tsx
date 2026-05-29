import React from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import { Globe, Send } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import {
  PathTabs,
  firstAccessibleTabPath,
  type PathTabSpec,
} from '@/shared/components/navigation/PathTabs';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { IngressRoutesPanel } from '@system/features/system/components/ingress/IngressRoutesPanel';
import { ExposeServicePanel } from '@system/features/system/components/ingress/ExposeServicePanel';

/**
 * Ingress hub — derived Traefik routes + the approval-gated Expose Service
 * wizard.
 *
 * Tabs (path-based per feedback_path_based_tabs):
 *   - Routes  (`/app/system/ingress/routes`)  — read-only monitor list.
 *   - Expose  (`/app/system/ingress/expose`)  — Concierge-driven wizard.
 *
 * Plan reference: Phase 2c (Ingress).
 */

const BASE_PATH = '/app/system/ingress';

type TabKey = 'routes' | 'expose';

const TABS: PathTabSpec<TabKey>[] = [
  {
    key: 'routes',
    label: 'Routes',
    permission: 'system.ingress.read',
    icon: <Globe className="w-4 h-4" />,
  },
  {
    key: 'expose',
    label: 'Expose Service',
    permission: 'system.ingress.manage',
    icon: <Send className="w-4 h-4" />,
  },
];

export const IngressPage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  if (!firstPath) {
    return (
      <PageContainer
        title="Ingress"
        description="Public ingress routes derived from issued certificates."
      >
        <div className="p-12 text-center text-theme-secondary text-sm">
          You don't have permission to view any ingress resources. Ask an admin to grant
          <code className="mx-1 font-mono">system.ingress.read</code> or
          <code className="mx-1 font-mono">system.ingress.manage</code>.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="Ingress"
      description="Public ingress routes derived from issued certificates, plus an approval-gated wizard to expose a service publicly."
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route path="/" element={<Navigate to={firstPath} replace />} />
          <Route path="routes" element={<IngressRoutesPanel />} />
          <Route path="expose" element={<ExposeServicePanel />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>
    </PageContainer>
  );
};

export default IngressPage;
