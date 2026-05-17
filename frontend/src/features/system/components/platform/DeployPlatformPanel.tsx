import React, { useEffect, useState } from 'react';
import { AlertTriangle, Rocket } from 'lucide-react';
import apiClient from '@/shared/services/apiClient';
import { logger } from '@/shared/utils/logger';
import type { ChatCard } from '@/shared/types/ai';
import { PlatformDeploymentWizardCard } from '@/features/ai/provisioning/PlatformDeploymentWizardCard';

/**
 * Standalone deploy panel — fetches the wizard payload from
 * GET /system/platform/deployments/wizard and renders the same
 * PlatformDeploymentWizardCard the chat surface uses. One source of
 * truth, two entry points (chat + dashboard).
 *
 * Plan reference: D4.2 (web UI parity with the chat card).
 */
export const DeployPlatformPanel: React.FC = () => {
  const [card, setCard] = useState<ChatCard | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    apiClient
      .get<{ data?: { card?: unknown } }>('/system/platform/deployments/wizard')
      .then((response) => {
        const inner = response.data?.data ?? response.data;
        const wizardCard = (inner as { card?: Record<string, unknown> })?.card;
        if (!wizardCard) {
          if (!cancelled) setError('Wizard payload missing `card` shape');
          return;
        }
        // Wrap the payload in a ChatCard envelope so the existing
        // PlatformDeploymentWizardCard component (designed for chat
        // surfaces) can render it unchanged.
        if (!cancelled) {
          setCard({
            kind: 'platform_deployment_wizard',
            tool: 'system_deploy_platform',
            arguments: {},
            payload: inner as Record<string, unknown>,
          });
        }
      })
      .catch((err) => {
        const msg = err instanceof Error ? err.message : 'Failed to load wizard';
        logger.error('DeployPlatformPanel fetch failed', { err });
        if (!cancelled) setError(msg);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (loading) {
    return (
      <div className="p-6 bg-theme-surface border border-theme rounded">
        <div className="animate-pulse">
          <div className="h-6 bg-theme-background-secondary rounded w-1/3 mb-3"></div>
          <div className="h-32 bg-theme-background-secondary rounded"></div>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="p-3 bg-theme-danger text-theme-danger text-sm rounded inline-flex items-center gap-2">
        <AlertTriangle className="w-4 h-4" />
        {error}
      </div>
    );
  }

  if (!card) return null;

  return (
    <div>
      <div className="flex items-center gap-2 mb-3">
        <Rocket className="w-5 h-5 text-theme-info" />
        <h2 className="text-lg font-semibold text-theme-primary">Deploy a New Platform</h2>
      </div>
      <p className="text-sm text-theme-secondary mb-4">
        Provision a new Powernode platform — standalone (sovereign) or federated (peered with this
        platform on first boot). Stateful service roles can be backed by an existing storage volume;
        ACME cert issuance happens automatically post-boot when a public DNS hostname is set.
      </p>
      <PlatformDeploymentWizardCard card={card} />
    </div>
  );
};

export default DeployPlatformPanel;
