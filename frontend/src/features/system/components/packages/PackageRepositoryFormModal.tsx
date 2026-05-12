import { FC, useEffect, useMemo, useState } from 'react';
import { Check } from 'lucide-react';
import { packageRepositoriesApi, type SystemPackageRepository, type PackageRepositoryCreate } from '@system/features/system/services/api/packageRepositoriesApi';
import { architecturesApi } from '@system/features/system/services/api/architecturesApi';
import { usePermissions } from '@/shared/hooks/usePermissions';
import { logger } from '@/shared/utils/logger';
import { MultiSelect, type MultiSelectOption } from '@/shared/components/ui/MultiSelect';
import type { SystemNodeArchitecture } from '@system/features/system/types/system.types';

interface Props {
  repository: SystemPackageRepository | null;
  open: boolean;
  onClose: () => void;
  onSaved: (repo: SystemPackageRepository) => void;
}

type Kind = 'apt' | 'rpm' | 'dnf';

const FAMILY_ORDER = ['x86', 'arm', 'power', 'z', 'risc-v', 'mips', 'other'];

// Resolve any input form (canonical name, apt_name, rpm_name, or alias)
// to the catalog row's canonical `name`. Returns the original input
// when no catalog match is found (preserves operator-entered tags
// during edit; the backend's canonicalize_architectures hook drops
// truly unmappable entries on save).
function toCanonical(value: string, catalog: SystemNodeArchitecture[]): string {
  const norm = value.trim().toLowerCase();
  const match = catalog.find(
    (a) =>
      a.name.toLowerCase() === norm ||
      (a.apt_name && a.apt_name.toLowerCase() === norm) ||
      (a.rpm_name && a.rpm_name.toLowerCase() === norm) ||
      (a.aliases?.some((al) => al.toLowerCase() === norm))
  );
  return match?.name ?? value;
}

// Architectures are stored canonical (T2.A) — the dropdown VALUE is the
// canonical name. The LABEL prefers the kind-specific name for operator
// readability ("x86_64" reads naturally in an rpm context even though the
// stored value is "amd64"), and the secondaryLabel shows the alternate
// convention so the operator sees the equivalence at a glance.
function archOptionsForKind(catalog: SystemNodeArchitecture[], kind: Kind): MultiSelectOption[] {
  const field: 'apt_name' | 'rpm_name' = kind === 'apt' ? 'apt_name' : 'rpm_name';
  return catalog
    .filter((a) => a.enabled)
    .map((a) => {
      const primary = a[field] ?? a.name;
      const alt = field === 'apt_name' ? a.rpm_name ?? a.name : a.apt_name ?? a.name;
      return {
        // Wire value: canonical (apt-convention per prior session).
        // Backend's adapter translates to kind-specific at sync time.
        value: a.name,
        // Display: kind-specific reads naturally in context, but canonical
        // is what gets stored — show alt in parens to make the mapping
        // visible.
        label: primary,
        secondaryLabel: alt && alt !== primary ? alt : undefined,
        description: a.description,
        group: familyLabel(a.family),
      };
    });
}

function familyLabel(family: string): string {
  switch (family) {
    case 'x86':     return 'x86 (Intel/AMD)';
    case 'arm':     return 'ARM';
    case 'power':   return 'Power';
    case 'z':       return 'IBM Z';
    case 'risc-v':  return 'RISC-V';
    case 'mips':    return 'MIPS';
    default:        return 'Other';
  }
}

const GROUP_ORDER = FAMILY_ORDER.map(familyLabel);

// Kind-conditional form: apt fields (suite/components) vs rpm fields
// (releasever/gpgcheck/metalink) toggle based on kind selection. Visibility
// = "shared" requires system.package_repositories.manage_shared.
export const PackageRepositoryFormModal: FC<Props> = ({ repository, open, onClose, onSaved }) => {
  const { hasPermission } = usePermissions();
  const canManageShared = hasPermission('system.package_repositories.manage_shared');

  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [kind, setKind] = useState<Kind>('apt');
  const [visibility, setVisibility] = useState<'account' | 'shared'>('account');
  const [baseUrl, setBaseUrl] = useState('');
  const [archs, setArchs] = useState<string[]>(['amd64']);
  const [aptSuite, setAptSuite] = useState('');
  const [aptComponents, setAptComponents] = useState('main');
  const [rpmReleasever, setRpmReleasever] = useState('');
  const [rpmGpgcheck, setRpmGpgcheck] = useState(true);
  const [signingKey, setSigningKey] = useState('');
  const [enabled, setEnabled] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [catalog, setCatalog] = useState<SystemNodeArchitecture[]>([]);
  const [catalogLoading, setCatalogLoading] = useState(false);
  const [translationMessage, setTranslationMessage] = useState<string | null>(null);

  // Load the architecture catalog once when the modal opens.
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setCatalogLoading(true);
    architecturesApi
      .getArchitectures({ enabled: true })
      .then((rows) => { if (!cancelled) setCatalog(rows); })
      .catch((err) => { logger.error('[PackageRepoForm] catalog load failed', err); })
      .finally(() => { if (!cancelled) setCatalogLoading(false); });
    return () => { cancelled = true; };
  }, [open]);

  // Reset form when (re)opening.
  useEffect(() => {
    if (repository) {
      setName(repository.name);
      setDescription(repository.description ?? '');
      setKind(repository.kind);
      setVisibility(repository.visibility);
      setBaseUrl(repository.base_url);
      // Stored architectures are canonical (post-T2.A) but be defensive
      // and re-canonicalize via the catalog on load — handles any stale
      // pre-T2.A rows that slipped through and any user-supplied non-
      // canonical strings the backend's hook would normalize on save.
      setArchs(
        repository.architectures
          .map((s) => toCanonical(s.trim(), catalog))
          .filter(Boolean)
      );
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
      setArchs(['amd64']);
      setAptSuite('');
      setAptComponents('main');
      setRpmReleasever('');
      setRpmGpgcheck(true);
      setSigningKey('');
      setEnabled(true);
    }
    setError(null);
    setTranslationMessage(null);
  }, [repository, open]);

  // Auto-dismiss kind-translation banner after 4s.
  useEffect(() => {
    if (!translationMessage) return;
    const t = setTimeout(() => setTranslationMessage(null), 4000);
    return () => clearTimeout(t);
  }, [translationMessage]);

  const onKindChange = (next: Kind) => {
    const prev = kind;
    setKind(next);
    // Architectures are stored canonical — they don't need translation
    // across a kind toggle. Only the displayed label changes (the
    // dropdown re-renders kind-specific labels via archOptions). The
    // inline banner stays useful for visual confirmation that the
    // operator's selection still resolves on the new side.
    if (prev === next || catalog.length === 0 || archs.length === 0) return;

    const visibleNow = archs
      .map((canonical) => {
        const row = catalog.find((a) => a.name === canonical);
        if (!row) return canonical;
        return next === 'apt' ? row.apt_name ?? row.name : row.rpm_name ?? row.name;
      })
      .join(', ');
    setTranslationMessage(
      `Showing ${next} names: ${visibleNow}. (Canonical values unchanged — backend translates per-kind at sync.)`
    );
  };

  const archOptions = useMemo(() => archOptionsForKind(catalog, kind), [catalog, kind]);

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
      architectures: archs.map((s) => s.trim()).filter(Boolean),
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
              onChange={(e) => onKindChange(e.target.value as Kind)}
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
          <div className="block">
            <span className="text-xs text-theme-secondary">Architectures</span>
            <MultiSelect
              options={archOptions}
              value={archs}
              onChange={setArchs}
              placeholder={catalogLoading ? 'Loading catalog…' : 'Select architectures…'}
              searchPlaceholder="Filter by name or family…"
              emptyMessage={catalogLoading ? 'Loading…' : 'No matches in the catalog'}
              groupOrder={GROUP_ORDER}
              ariaLabel="Repository architectures"
              className="mt-1"
            />
            {translationMessage && (
              <p className="mt-1 text-xs text-theme-info flex items-center gap-1">
                <Check className="w-3 h-3" />
                {translationMessage}
              </p>
            )}
          </div>
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
