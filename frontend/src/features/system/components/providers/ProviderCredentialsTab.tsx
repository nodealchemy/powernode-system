import React from 'react';
import { CheckCircle2 } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import {
  ProviderCredentialForm,
  type CredentialTestStatus,
  type ProviderTypeSlug,
  type ProviderCredentialValues,
} from '@/features/onboarding/ProviderCredentialForm';
import type { SystemProvider } from '@system/features/system/types/system.types';
import { CREDENTIAL_TAB_EXCLUDE_SCOPES } from './providerFormHelpers';

export interface ProviderCredentialsTabProps {
  effectiveProvider: SystemProvider;
  /** Set only when the modal was opened in edit mode (not just-created). */
  editProvider?: SystemProvider | null;
  /** The just-created provider, when this save flow created a new one. */
  createdProvider: SystemProvider | null;
  onboardingType: ProviderTypeSlug | null;
  providerType: string;
  credentialsValid: boolean;
  testStatus: CredentialTestStatus;
  savingCredentials: boolean;
  credentialSaved: boolean;
  onCredentialsChange: (values: ProviderCredentialValues, valid: boolean) => void;
  onTestStatusChange: (status: CredentialTestStatus) => void;
  onSaveCredentials: () => void;
  onClose: () => void;
}

export const ProviderCredentialsTab: React.FC<ProviderCredentialsTabProps> = ({
  effectiveProvider,
  editProvider,
  createdProvider,
  onboardingType,
  providerType,
  credentialsValid,
  testStatus,
  savingCredentials,
  credentialSaved,
  onCredentialsChange,
  onTestStatusChange,
  onSaveCredentials,
  onClose,
}) => (
  <div
    className="p-4 space-y-4 max-h-[70vh] overflow-y-auto"
    data-testid="provider-form-credentials-panel"
  >
    {!editProvider && createdProvider && (
      <div className="rounded-lg border border-theme-success-border/40 bg-theme-success-bg p-3 text-sm text-theme-secondary">
        <p className="font-medium text-theme-primary">
          Provider "{createdProvider.name}" created.
        </p>
        <p className="mt-1 text-xs">
          Fill in credentials below and click <span className="font-medium text-theme-secondary">Test</span>{' '}
          then <span className="font-medium text-theme-secondary">Save credentials</span> to finish,
          or click <span className="font-medium text-theme-secondary">Close</span> to add them later.
        </p>
      </div>
    )}
    {onboardingType ? (
      <>
        <ProviderCredentialForm
          category="cloud"
          providerType={onboardingType}
          providerId={effectiveProvider.id}
          excludeScopes={CREDENTIAL_TAB_EXCLUDE_SCOPES}
          onChange={onCredentialsChange}
          onTestStatusChange={onTestStatusChange}
        />
        <div className="flex flex-wrap items-center gap-3 border-t border-theme pt-3">
          <Button
            type="button"
            variant="primary"
            size="sm"
            onClick={onSaveCredentials}
            disabled={
              !credentialsValid ||
              savingCredentials ||
              (onboardingType !== 'localqemu' && testStatus !== 'valid')
            }
            data-testid="provider-form-save-credentials-btn"
          >
            {savingCredentials ? (
              <>
                <LoadingSpinner size="sm" className="mr-2" />
                Saving…
              </>
            ) : credentialSaved ? (
              'Saved'
            ) : (
              'Save credentials'
            )}
          </Button>
          {credentialSaved && (
            <span className="flex items-center gap-1 text-xs text-theme-success-fg">
              <CheckCircle2 className="h-4 w-4" />
              Credentials encrypted and stored.
            </span>
          )}
        </div>
      </>
    ) : (
      <div className="rounded-lg border border-theme bg-theme-warning-bg p-4 text-sm text-theme-secondary">
        <p className="font-medium text-theme-primary">
          No credential schema for {providerType}.
        </p>
        <p className="mt-1 text-xs">
          The BYOC credential entry form supports AWS, Hetzner, DigitalOcean, Vultr,
          GCP, Azure, and LocalQemu. For other provider types, use the legacy
          Configuration JSON on the General tab.
        </p>
      </div>
    )}
    <div className="flex justify-end pt-2 border-t border-theme">
      <Button type="button" variant="outline" onClick={onClose}>
        Close
      </Button>
    </div>
  </div>
);

export default ProviderCredentialsTab;
