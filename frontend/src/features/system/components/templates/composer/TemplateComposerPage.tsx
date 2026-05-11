import React, { useCallback, useMemo, useState } from 'react';
import { AlertTriangle, ArrowDown, ArrowUp, Plus, Save, X } from 'lucide-react';
import { Button } from '@/shared/components/ui/Button';
import { Badge } from '@/shared/components/ui/Badge';
import { useNotifications } from '@/shared/hooks/useNotifications';
import { systemApi } from '@system/features/system/services/systemApi';
import type { SystemNodeModule } from '@system/features/system/types/system.types';
import type {
  TemplateComposePreview,
  TemplateComposeConflict,
} from '@system/features/system/services/api/templatesApi';
import { SaveTemplateModal } from './SaveTemplateModal';

// Visual Template Composer (Golden Eclipse plan M-FE-1).
// Split-view layout:
//   - Left: ModuleCatalogPanel (search + add to composition)
//   - Right: ComposerCanvas (priority-ordered stack)
//   - Bottom: ConflictPanel + footprint summary
//
// Compose-preview round-trips through POST /system/node_templates/compose_preview
// every time the composition changes. The backend computes conflicts and
// dependency graph; the frontend just renders.
//
// Future hooks: drag-and-drop reordering of priority via ComposerCanvas
// rows, dependency-graph visualization (react-flow), save-as-template
// modal that feeds the same module_ids into POST /node_templates.
export function TemplateComposerPage(): React.JSX.Element {
  const { addNotification } = useNotifications();
  const [selectedModules, setSelectedModules] = useState<SystemNodeModule[]>([]);
  const [preview, setPreview] = useState<TemplateComposePreview | null>(null);
  const [previewing, setPreviewing] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [catalog, setCatalog] = useState<SystemNodeModule[]>([]);
  const [catalogLoading, setCatalogLoading] = useState(false);
  const [showSaveModal, setShowSaveModal] = useState(false);

  // Refresh the module catalog. v0 fetches once; M-FE-1.1 will use
  // useInfiniteResourceList for scrolling + search backend-side.
  const refreshCatalog = useCallback(async () => {
    setCatalogLoading(true);
    try {
      const response = await systemApi.getModules({ per_page: 200 });
      setCatalog(response.modules ?? []);
    } catch (error) {
      addNotification({ type: 'error', message: 'Failed to load module catalog' });
    } finally {
      setCatalogLoading(false);
    }
  }, [addNotification]);

  React.useEffect(() => {
    void refreshCatalog();
  }, [refreshCatalog]);

  const filteredCatalog = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    const selectedIds = new Set(selectedModules.map((m) => m.id));
    return catalog
      .filter((m) => !selectedIds.has(m.id))
      .filter((m) => !q || m.name.toLowerCase().includes(q) || (m.variety ?? '').toLowerCase().includes(q));
  }, [catalog, searchQuery, selectedModules]);

  const requestPreview = useCallback(
    async (modules: SystemNodeModule[]) => {
      if (modules.length === 0) {
        setPreview(null);
        return;
      }
      setPreviewing(true);
      try {
        const ids = modules.map((m) => m.id);
        const result = await systemApi.composePreview(ids);
        setPreview(result);
      } catch (error) {
        addNotification({ type: 'error', message: 'Compose preview failed' });
      } finally {
        setPreviewing(false);
      }
    },
    [addNotification]
  );

  const addModule = useCallback(
    (module: SystemNodeModule) => {
      const next = [...selectedModules, module];
      setSelectedModules(next);
      void requestPreview(next);
    },
    [requestPreview, selectedModules]
  );

  const removeModule = useCallback(
    (moduleId: string) => {
      const next = selectedModules.filter((m) => m.id !== moduleId);
      setSelectedModules(next);
      void requestPreview(next);
    },
    [requestPreview, selectedModules]
  );

  const moveModule = useCallback(
    (moduleId: string, direction: 'up' | 'down') => {
      const idx = selectedModules.findIndex((m) => m.id === moduleId);
      if (idx === -1) return;
      const target = direction === 'up' ? idx - 1 : idx + 1;
      if (target < 0 || target >= selectedModules.length) return;
      const next = [...selectedModules];
      [next[idx], next[target]] = [next[target], next[idx]];
      setSelectedModules(next);
      void requestPreview(next);
    },
    [requestPreview, selectedModules]
  );

  const conflicts = preview?.conflicts ?? [];
  const footprint = preview?.footprint;

  return (
    <div className="flex flex-col h-full bg-theme-background text-theme-foreground">
      <header className="px-6 py-4 border-b border-theme flex items-start justify-between">
        <div>
          <h1 className="text-xl font-semibold">Template Composer</h1>
          <p className="text-sm text-theme-muted mt-1">
            Drag modules from the catalog into the composition. Conflicts and footprint
            estimate update live as you compose.
          </p>
        </div>
        <Button
          onClick={() => setShowSaveModal(true)}
          disabled={selectedModules.length === 0 || conflicts.length > 0}
          variant="primary"
        >
          <Save size={14} /> Save as Template
        </Button>
      </header>

      {showSaveModal && (
        <SaveTemplateModal
          modules={selectedModules}
          conflicts={conflicts}
          onClose={() => setShowSaveModal(false)}
          onSaved={(template) => {
            setShowSaveModal(false);
            addNotification({ type: 'success', message: `Template ${template.name} created` });
            setSelectedModules([]);
            setPreview(null);
          }}
        />
      )}

      <div className="flex-1 grid grid-cols-1 md:grid-cols-2 gap-4 p-4 overflow-hidden">
        {/* Module Catalog */}
        <section className="flex flex-col bg-theme-surface rounded-lg border border-theme overflow-hidden">
          <div className="px-4 py-3 border-b border-theme">
            <h2 className="font-medium">Module Catalog</h2>
            <input
              type="search"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search modules..."
              className="mt-2 w-full px-3 py-2 text-sm rounded border border-theme bg-theme-background"
            />
          </div>
          <div className="flex-1 overflow-y-auto">
            {catalogLoading ? (
              <p className="p-4 text-sm text-theme-muted">Loading catalog…</p>
            ) : filteredCatalog.length === 0 ? (
              <p className="p-4 text-sm text-theme-muted">No modules match.</p>
            ) : (
              <ul className="divide-y divide-theme-border">
                {filteredCatalog.map((m) => (
                  <li key={m.id} className="px-4 py-3 flex items-center justify-between hover:bg-theme-surface-hover">
                    <div>
                      <div className="font-medium text-sm">{m.name}</div>
                      <div className="text-xs text-theme-muted">
                        variety={m.variety} · priority={m.priority}
                      </div>
                    </div>
                    <Button size="sm" onClick={() => addModule(m)} variant="secondary">
                      <Plus size={14} /> Add
                    </Button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>

        {/* Composition Canvas */}
        <section className="flex flex-col bg-theme-surface rounded-lg border border-theme overflow-hidden">
          <div className="px-4 py-3 border-b border-theme flex items-center justify-between">
            <h2 className="font-medium">Composition</h2>
            <div className="text-xs text-theme-muted">
              {selectedModules.length} module(s)
              {previewing && ' · previewing…'}
            </div>
          </div>
          <div className="flex-1 overflow-y-auto">
            {selectedModules.length === 0 ? (
              <p className="p-4 text-sm text-theme-muted">
                Add modules from the catalog to begin composing a template.
              </p>
            ) : (
              <ul className="divide-y divide-theme-border">
                {selectedModules.map((m, idx) => (
                  <li key={m.id} className="px-4 py-3 flex items-center gap-3 hover:bg-theme-surface-hover">
                    <span className="font-mono text-xs text-theme-muted w-6">{idx + 1}.</span>
                    <div className="flex-1">
                      <div className="font-medium text-sm">{m.name}</div>
                      <div className="text-xs text-theme-muted">{m.variety}</div>
                    </div>
                    <Button size="xs" variant="ghost" onClick={() => moveModule(m.id, 'up')} disabled={idx === 0}>
                      <ArrowUp size={14} />
                    </Button>
                    <Button size="xs" variant="ghost" onClick={() => moveModule(m.id, 'down')} disabled={idx === selectedModules.length - 1}>
                      <ArrowDown size={14} />
                    </Button>
                    <Button size="xs" variant="ghost" onClick={() => removeModule(m.id)}>
                      <X size={14} />
                    </Button>
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>
      </div>

      {/* Conflicts + Footprint footer panel */}
      <footer className="border-t border-theme bg-theme-surface px-6 py-4 grid grid-cols-1 md:grid-cols-2 gap-4">
        <ConflictPanel conflicts={conflicts} />
        <FootprintPanel footprint={footprint} />
      </footer>
    </div>
  );
}

function ConflictPanel({ conflicts }: { conflicts: TemplateComposeConflict[] }): React.JSX.Element {
  if (conflicts.length === 0) {
    return (
      <div className="text-sm text-theme-muted">
        <span className="font-medium text-theme-foreground">No conflicts detected.</span>
      </div>
    );
  }
  return (
    <div>
      <div className="flex items-center gap-2 text-sm font-medium mb-2">
        <AlertTriangle size={14} className="text-theme-warning" />
        Conflicts ({conflicts.length})
      </div>
      <ul className="space-y-1 text-xs">
        {conflicts.map((c, i) => (
          <li key={i} className="flex items-start gap-2">
            <Badge variant="warning">{c.kind}</Badge>
            <span className="text-theme-muted">{c.detail}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function FootprintPanel({ footprint }: { footprint?: TemplateComposePreview['footprint'] }): React.JSX.Element {
  if (!footprint) {
    return <div className="text-sm text-theme-muted">Footprint will appear once you add modules.</div>;
  }
  return (
    <div className="text-sm">
      <div className="font-medium mb-2">Footprint</div>
      <div className="grid grid-cols-3 gap-3 text-xs">
        <div>
          <div className="text-theme-muted">Modules</div>
          <div className="text-base font-mono">{footprint.module_count}</div>
        </div>
        <div>
          <div className="text-theme-muted">Packages (est.)</div>
          <div className="text-base font-mono">{footprint.estimated_package_count}</div>
        </div>
        <div>
          <div className="text-theme-muted">Arch</div>
          <div className="text-base font-mono">{footprint.architectures.join(', ') || '—'}</div>
        </div>
      </div>
    </div>
  );
}

export default TemplateComposerPage;
