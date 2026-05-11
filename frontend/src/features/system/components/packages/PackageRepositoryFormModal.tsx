import { FC, useEffect, useState } from 'react';
import { packageRepositoriesApi, type SystemPackageRepository, type PackageRepositoryCreate } from '@system/features/system/services/api/packageRepositoriesApi';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { logger } from '@/shared/utils/logger';

interface Props {
  repository: SystemPackageRepository | null;
  open: boolean;
  onClose: () => void;
  onSaved: (repo: SystemPackageRepository) => void;
}

// Kind-conditional form: apt fields (suite/components) vs rpm fields
// (releasever/gpgcheck/metalink) toggle based on kind selection. Visibility
// = "shared" requires system.package_repositories.manage_shared.
export const PackageRepositoryFormModal: FC<Props> = ({ repository, open, onClose, onSaved }) => {
  const { hasPermission } = usePermissions();
  const canManageShared = hasPermission('system.package_repositories.manage_shared');

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [kind, setKind] = useState<'apt' | 'rpm' | 'dnf'>('apt');
  const [visibility, setVisibility] = useState<'account' | 'shared'>('account');
  const [baseUrl, setBaseUrl] = useState('');
  const [archs, setArchs] = useState('amd64');
  const [aptSuite, setAptSuite] = useState('');
  const [aptComponents, setAptComponents] = useState('main');
  const [rpmReleasever, setRpmReleasever] = useState('');
  const [rpmGpgcheck, setRpmGpgcheck] = useState(true);
  const [signingKey, setSigningKey] = useState('');
  const [enabled, setEnabled] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (repository) {
      setName(repository.name);
      setDescription(repository.description ?? '');
      setKind(repository.kind);
      setVisibility(repository.visibility);
      setBaseUrl(repository.base_url);
      setArchs(repository.architectures.join(','));
      setAptSuite((repository.apt_config?.suite as string) ?? '');
      setAptComponents(((repository.apt_config?.components as string[]) ?? []).join(','));
      setRpmReleasever((repository.rpm_config?.releasever as string) ?? '');
      setRpmGpgcheck((repository.rpm_config?.gpgcheck as boolean) ?? true);
      setEnabled(repository.enabled);
    } else {
      setName('');
      setDescription('');
      setKind('apt');
      setVisibility('account');
      setBaseUrl('');
      setArchs('amd64');
      setAptSuite('');
      setAptComponents('main');
      setRpmReleasever('');
      setRpmGpgcheck(true);
      setSigningKey('');
      setEnabled(true);
    }
    setError(null);
  }, [repository, open]);

  if (!open) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setSaving(true);
    setError(null);
    const payload: PackageRepositoryCreate = {
      name,
      description,
      kind,
      visibility,
      base_url: baseUrl,
      architectures: archs.split(',').map((s) => s.trim()).filter(Boolean),
      enabled,
    };
    if (signingKey.trim()) payload.signing_key_armor = signingKey;
    if (kind === 'apt') {
      payload.apt_config = {
        suite: aptSuite,
        components: aptComponents.split(',').map((s) => s.trim()).filter(Boolean),
      };
    } else {
      payload.rpm_config = { releasever: rpmReleasever, gpgcheck: rpmGpgcheck };
    }
    try {
      const saved = repository
        ? await packageRepositoriesApi.update(repository.id, payload)
        : await packageRepositoriesApi.create(payload);
      onSaved(saved);
      onClose();
    } catch (err) {
      logger.error('[PackageRepoForm] save failed', err);
      setError(err instanceof Error ? err.message : 'Save failed');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <form
        onSubmit={handleSubmit}
        className="w-full max-w-2xl bg-theme-surface rounded-lg shadow-xl p-6 max-h-[90vh] overflow-y-auto"
      >
        <h2 className="text-lg font-semibold text-theme-primary mb-4">
          {repository ? 'Edit Package Repository' : 'Create Package Repository'}
        </h2>

        {error && (
          <div className="mb-3 p-2 bg-theme-danger/10 text-theme-danger rounded text-sm">{error}</div>
        )}

        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className="text-xs text-theme-secondary">Name</span>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              required
              className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
            />
          </label>
          <label className="block">
            <span className="text-xs text-theme-secondary">Kind</span>
            <select
              value={kind}
              onChange={(e) => setKind(e.target.value as 'apt' | 'rpm' | 'dnf')}
              className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
            >
              <option value="apt">apt (Debian/Ubuntu)</option>
              <option value="rpm">rpm (RHEL/Fedora)</option>
              <option value="dnf">dnf (Fedora modular)</option>
            </select>
          </label>
        </div>

        <label className="block mt-3">
          <span className="text-xs text-theme-secondary">Description</span>
          <input
            type="text"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
          />
        </label>

        <label className="block mt-3">
          <span className="text-xs text-theme-secondary">Base URL</span>
          <input
            type="url"
            value={baseUrl}
            onChange={(e) => setBaseUrl(e.target.value)}
            required
            placeholder="https://archive.ubuntu.com/ubuntu"
            className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
          />
        </label>

        <div className="grid grid-cols-2 gap-3 mt-3">
          <label className="block">
            <span className="text-xs text-theme-secondary">Architectures (comma-separated)</span>
            <input
              type="text"
              value={archs}
              onChange={(e) => setArchs(e.target.value)}
              placeholder="amd64,arm64"
              className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
            />
          </label>
          <label className="block">
            <span className="text-xs text-theme-secondary">Visibility</span>
            <select
              value={visibility}
              onChange={(e) => setVisibility(e.target.value as 'account' | 'shared')}
              disabled={!canManageShared && visibility !== 'shared'}
              className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
            >
              <option value="account">Account (private)</option>
              <option value="shared" disabled={!canManageShared}>
                Shared (system-wide) {!canManageShared && '— admin only'}
              </option>
            </select>
          </label>
        </div>

        {kind === 'apt' && (
          <div className="mt-3 p-3 bg-theme-background-secondary rounded">
            <div className="text-xs text-theme-secondary mb-2">Apt configuration</div>
            <div className="grid grid-cols-2 gap-3">
              <label className="block">
                <span className="text-xs text-theme-secondary">Suite</span>
                <input
                  type="text"
                  value={aptSuite}
                  onChange={(e) => setAptSuite(e.target.value)}
                  placeholder="noble"
                  className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
                />
              </label>
              <label className="block">
                <span className="text-xs text-theme-secondary">Components (comma-separated)</span>
                <input
                  type="text"
                  value={aptComponents}
                  onChange={(e) => setAptComponents(e.target.value)}
                  placeholder="main,universe"
                  className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
                />
              </label>
            </div>
          </div>
        )}

        {kind !== 'apt' && (
          <div className="mt-3 p-3 bg-theme-background-secondary rounded">
            <div className="text-xs text-theme-secondary mb-2">RPM configuration</div>
            <div className="grid grid-cols-2 gap-3 items-end">
              <label className="block">
                <span className="text-xs text-theme-secondary">Release version</span>
                <input
                  type="text"
                  value={rpmReleasever}
                  onChange={(e) => setRpmReleasever(e.target.value)}
                  placeholder="40"
                  className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary"
                />
              </label>
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={rpmGpgcheck}
                  onChange={(e) => setRpmGpgcheck(e.target.checked)}
                />
                <span className="text-xs text-theme-secondary">Verify GPG signatures</span>
              </label>
            </div>
          </div>
        )}

        <label className="block mt-3">
          <span className="text-xs text-theme-secondary">Signing public key (PEM/ASCII-armored, optional)</span>
          <textarea
            value={signingKey}
            onChange={(e) => setSigningKey(e.target.value)}
            rows={4}
            placeholder="-----BEGIN PGP PUBLIC KEY BLOCK-----..."
            className="w-full mt-1 px-2 py-1.5 rounded border border-theme bg-theme-background text-theme-primary font-mono text-xs"
          />
        </label>

        <label className="flex items-center gap-2 mt-3">
          <input
            type="checkbox"
            checked={enabled}
            onChange={(e) => setEnabled(e.target.checked)}
          />
          <span className="text-sm text-theme-primary">Enabled</span>
        </label>

        <div className="mt-5 flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="px-3 py-2 text-sm rounded border border-theme text-theme-secondary hover:text-theme-primary"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={saving}
            className="px-4 py-2 text-sm rounded bg-theme-focus text-white hover:opacity-90 disabled:opacity-50"
          >
            {saving ? 'Saving…' : repository ? 'Save Changes' : 'Create Repository'}
          </button>
        </div>
      </form>
    </div>
  );
};
