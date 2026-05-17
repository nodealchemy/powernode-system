import React from 'react';
import { Routes, Route, Link, Navigate, useLocation } from 'react-router-dom';
import { KeyRound, ShieldCheck } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { AcmeDnsCredentialsPanel } from '@system/features/system/components/acme/AcmeDnsCredentialsPanel';
import { AcmeCertificatesPanel } from '@system/features/system/components/acme/AcmeCertificatesPanel';

/**
 * ACME hub — DNS provider credentials + issued certificates.
 *
 * Tabs (path-based per feedback_path_based_tabs):
 *   - DNS Credentials (`/app/system/acme/dns-credentials`)
 *   - Certificates    (`/app/system/acme/certificates`)
 *
 * Plan reference: Decentralized Federation §J + P2.5.8 + P2.5.9.
 */

type TabKey = 'dns-credentials' | 'certificates';

interface TabSpec {
  key: TabKey;
  label: string;
  permission: string;
  icon: React.ReactNode;
}

const TABS: TabSpec[] = [
  {
    key: 'dns-credentials',
    label: 'DNS Credentials',
    permission: 'system.acme_dns.read',
    icon: <KeyRound className="w-4 h-4" />,
  },
  {
    key: 'certificates',
    label: 'Certificates',
    permission: 'system.acme.read',
    icon: <ShieldCheck className="w-4 h-4" />,
  },
];

export const AcmePage: React.FC = () => {
  const { hasPermission } = usePermissions();
  const location = useLocation();

  const accessibleTabs = TABS.filter((t) => hasPermission(t.permission));
  const activeKey = (() => {
    const seg = location.pathname.split('/').filter(Boolean).pop();
    const match = accessibleTabs.find((t) => t.key === seg);
    return match?.key ?? accessibleTabs[0]?.key ?? 'dns-credentials';
  })();

  if (accessibleTabs.length === 0) {
    return (
      <PageContainer
        title="ACME"
        icon={KeyRound}
        description="DNS provider credentials + Let's Encrypt certificate lifecycle."
      >
        <div className="p-12 text-center text-theme-secondary text-sm">
          You don't have permission to view any ACME resources. Ask an admin to grant
          <code className="mx-1 font-mono">system.acme_dns.read</code> or
          <code className="mx-1 font-mono">system.acme.read</code>.
        </div>
      </PageContainer>
    );
  }

  return (
    <PageContainer
      title="ACME"
      icon={KeyRound}
      description="DNS provider credentials + Let's Encrypt certificate lifecycle. The platform uses these to solve ACME DNS-01 challenges automatically."
    >
      <nav className="flex items-center gap-1 border-b border-theme mb-4">
        {accessibleTabs.map((tab) => {
          const isActive = activeKey === tab.key;
          return (
            <Link
              key={tab.key}
              to={`/app/system/acme/${tab.key}`}
              className={`px-3 py-2 text-sm inline-flex items-center gap-2 border-b-2 transition-colors ${
                isActive
                  ? 'border-theme-info text-theme-primary font-medium'
                  : 'border-transparent text-theme-secondary hover:text-theme-primary'
              }`}
            >
              {tab.icon}
              {tab.label}
            </Link>
          );
        })}
      </nav>

      <Routes>
        <Route
          path="/"
          element={<Navigate to={`/app/system/acme/${accessibleTabs[0].key}`} replace />}
        />
        <Route path="dns-credentials" element={<AcmeDnsCredentialsPanel />} />
        <Route path="certificates" element={<AcmeCertificatesPanel />} />
        <Route
          path="*"
          element={<Navigate to={`/app/system/acme/${accessibleTabs[0].key}`} replace />}
        />
      </Routes>
    </PageContainer>
  );
};

export default AcmePage;
