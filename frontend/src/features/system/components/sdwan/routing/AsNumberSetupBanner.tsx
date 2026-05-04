import React, { useState } from 'react';
import { Cpu, CheckCircle } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { sdwanApi } from '../../../services/api/sdwanApi';
import type { SdwanAccountBgp } from '../../../types/sdwan.types';

interface AsNumberSetupBannerProps {
  accountBgp: SdwanAccountBgp | null;
  onAllocated?: (bgp: SdwanAccountBgp) => void;
  canManage?: boolean;
}

export const AsNumberSetupBanner: React.FC<AsNumberSetupBannerProps> = ({
  accountBgp,
  onAllocated,
  canManage = false,
}) => {
  const [allocating, setAllocating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  if (accountBgp) {
    return (
      <div className="flex items-center gap-3 p-3 bg-theme-success/30 border border-theme-success/30 rounded text-sm">
        <CheckCircle size={20} className="text-theme-success" />
        <div>
          <div className="font-medium text-theme-primary">
            Account AS allocated: <span className="font-mono">{accountBgp.as_number}</span>
          </div>
          <div className="text-xs text-theme-secondary mt-0.5">
            All iBGP networks in this account share this AS number. Router-ID strategy:{' '}
            <code className="font-mono">{accountBgp.router_id_strategy}</code>.
          </div>
        </div>
      </div>
    );
  }

  const handleAllocate = async () => {
    setAllocating(true);
    setError(null);
    try {
      const result = await sdwanApi.allocateAccountAs();
      onAllocated?.(result.account_bgp);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'AS allocation failed');
    } finally {
      setAllocating(false);
    }
  };

  return (
    <div className="flex items-center gap-3 p-3 bg-theme-warning/30 border border-theme-warning/30 rounded text-sm">
      <Cpu size={20} className="text-theme-warning shrink-0" />
      <div className="flex-1">
        <div className="font-medium text-theme-primary">No AS number allocated</div>
        <div className="text-xs text-theme-secondary mt-0.5">
          iBGP networks need a 4-byte private AS number (RFC 6996, range 4200000000–4294967294). The platform
          assigns one deterministically per account.
        </div>
        {error && <div className="text-theme-danger text-xs mt-1">{error}</div>}
      </div>
      {canManage && (
        <Button variant="primary" onClick={handleAllocate} disabled={allocating}>
          {allocating ? 'Allocating…' : 'Allocate AS'}
        </Button>
      )}
    </div>
  );
};
