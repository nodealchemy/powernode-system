import React from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import { KeyRound, ShieldCheck } from 'lucide-react';
import { PageContainer } from '@/shared/components/layout/PageContainer';
import {
  PathTabs,
  firstAccessibleTabPath,
  type PathTabSpec,
} from '@/shared/components/navigation/PathTabs';
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

const BASE_PATH = '/app/system/acme';

type TabKey = 'dns-credentials' | 'certificates';

const TABS: PathTabSpec<TabKey>[] = [
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
  const firstPath = firstAccessibleTabPath(TABS, BASE_PATH, hasPermission);

  if (!firstPath) {
    return (
      <PageContainer
        title="ACME"
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
      description="DNS provider credentials + Let's Encrypt certificate lifecycle. The platform uses these to solve ACME DNS-01 challenges automatically."
    >
      <PathTabs tabs={TABS} basePath={BASE_PATH} hasPermission={hasPermission}>
        <Routes>
          <Route path="/" element={<Navigate to={firstPath} replace />} />
          <Route path="dns-credentials" element={<AcmeDnsCredentialsPanel />} />
          <Route path="certificates" element={<AcmeCertificatesPanel />} />
          <Route path="*" element={<Navigate to={firstPath} replace />} />
        </Routes>
      </PathTabs>
    </PageContainer>
  );
};

export default AcmePage;
