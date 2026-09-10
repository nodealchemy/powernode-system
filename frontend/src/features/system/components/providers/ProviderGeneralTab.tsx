import React from 'react';
import { FormField } from '@/shared/components/ui/FormField';
import { Button } from '@/shared/components/ui/Button';
import { LoadingSpinner } from '@/shared/components/ui/LoadingSpinner';
import { providerTypes, type ProviderFormData } from './providerFormHelpers';
import { ProviderTypeDefaultsFields } from './ProviderTypeDefaultsFields';

export interface ProviderGeneralTabProps {
  formData: ProviderFormData;
  errors: Record<string, string>;
  submitting: boolean;
  isEditMode: boolean;
  setField: (name: string, value: string | boolean) => void;
  handleChange: (
    e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>
  ) => void;
  onSubmit: (e: React.FormEvent) => void;
  onClose: () => void;
}

export const ProviderGeneralTab: React.FC<ProviderGeneralTabProps> = ({
  formData,
  errors,
  submitting,
  isEditMode,
  setField,
  handleChange,
  onSubmit,
  onClose,
}) => (
  <form onSubmit={onSubmit}>
    <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
      {/* Name and Type */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <FormField
          label="Name"
          id="name"
          required
          value={formData.name}
          onChange={(v) => setField('name', v)}
          placeholder="e.g., Production AWS"
          error={errors.name}
        />

        <FormField
          label="Provider Type"
          id="provider_type"
          type="select"
          required
          value={formData.provider_type}
          onChange={(v) => setField('provider_type', v)}
          error={errors.provider_type}
          options={providerTypes.map(type => ({ value: type.value, label: type.label }))}
        />
      </div>

      {/* Description */}
      <FormField
        label="Description"
        id="description"
        type="textarea"
        rows={2}
        value={formData.description}
        onChange={(v) => setField('description', v)}
        placeholder="Provider description"
      />

      {/* Per-provider-type deployment defaults (C12 review F4 split) */}
      <ProviderTypeDefaultsFields formData={formData} errors={errors} setField={setField} />

      {/* Advanced configuration — collapsed by default. Most operators don't
          need to set anything here; provider-type-specific fields (above)
          and the Credentials tab cover the common case. The JSON shapes
          are stored in System::Provider#config / #capabilities respectively. */}
      <details className="rounded-lg border border-theme bg-theme-background-secondary">
        <summary className="cursor-pointer select-none px-3 py-2 text-sm font-medium text-theme-primary hover:bg-theme-surface-hover">
          Advanced configuration (raw JSON)
        </summary>
        <div className="space-y-4 px-3 pb-3 pt-1">
          <p className="text-xs text-theme-tertiary">
            Most providers don't need anything here. Credentials live on the{' '}
            <span className="font-medium text-theme-secondary">Credentials</span> tab; the
            fields below are escape hatches for provider-specific metadata. Leave both as{' '}
            <code className="rounded bg-theme-surface px-1 py-0.5">{'{}'}</code> if unsure.
          </p>

          {/* Configuration */}
          <FormField
            label={<>Configuration <span className="text-xs font-normal text-theme-tertiary">(stored as JSON in <code>System::Provider#config</code>)</span></>}
            id="config"
            type="textarea"
            rows={4}
            value={formData.config}
            onChange={(v) => setField('config', v)}
            placeholder='{}'
            className="font-mono text-sm"
            error={errors.config}
          />

          {/* Capabilities */}
          <FormField
            label={<>Capabilities <span className="text-xs font-normal text-theme-tertiary">(usually <code>{'{"supports": [...]}'}</code>; informational metadata)</span></>}
            id="capabilities"
            type="textarea"
            rows={4}
            value={formData.capabilities}
            onChange={(v) => setField('capabilities', v)}
            placeholder='{}'
            className="font-mono text-sm"
            error={errors.capabilities}
          />
        </div>
      </details>

      {/* Checkboxes */}
      <div className="flex flex-col sm:flex-row sm:items-center gap-4">
        <label className="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            name="enabled"
            checked={formData.enabled}
            onChange={handleChange}
            className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
          />
          <span className="text-sm text-theme-primary">Enabled</span>
        </label>

        <label className="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            name="public"
            checked={formData.public}
            onChange={handleChange}
            className="w-4 h-4 rounded border-theme bg-theme-background text-theme-info-fg focus:ring-theme-focus"
          />
          <span className="text-sm text-theme-primary">Public</span>
        </label>
      </div>
    </div>

    <div className="flex justify-end gap-3 p-4 border-t border-theme">
      <Button type="button" variant="outline" onClick={onClose}>
        Cancel
      </Button>
      <Button type="submit" variant="primary" disabled={submitting}>
        {submitting ? (
          <>
            <LoadingSpinner size="sm" className="mr-2" />
            {isEditMode ? 'Updating...' : 'Creating...'}
          </>
        ) : (
          isEditMode ? 'Update Provider' : 'Add Provider'
        )}
      </Button>
    </div>
  </form>
);

export default ProviderGeneralTab;
