import React, { useMemo } from 'react';
import {
  ReactFlow,
  Background,
  Controls,
  MarkerType,
  type Node,
  type Edge,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import { Share2 } from 'lucide-react';
import { autoArrangeNodes } from '@/shared/utils/workflowLayout';
import type { TemplateComposePreview } from '@system/features/system/services/api/templatesApi';

// DependencyGraphPanel — renders the `dependency_graph` half of
// POST /system/node_templates/compose_preview, which the composer previously
// fetched and threw away (Golden Eclipse plan M-FE-1, gap G5).
//
// The backend (System::TemplateComposerService#dependency_graph) emits one flat
// edge list in a single direction: source = the dependent, target = the thing it
// depends on. Two layers feed it — `parent_module` hierarchy ("depends_on") and
// System::ModuleDependency rows ("requires" | "recommends" | "conflicts" |
// "provides") — so edges are styled per kind rather than uniformly.
//
// Layout is dagre (shared `autoArrangeNodes`, same helper the mission task graph
// uses) so the ranking matches the rest of the platform's graphs.

type DependencyGraph = TemplateComposePreview['dependency_graph'];

// The compose_preview payload carries a few fields the shared response type in
// templatesApi does not declare yet (`explicit`/`auto_resolved` on nodes,
// `required`/`version_constraint` on edges). Treat them as optional enrichments
// so the panel renders correctly with or without them.
type GraphNode = DependencyGraph['nodes'][number] & {
  explicit?: boolean;
  auto_resolved?: boolean;
};

type GraphEdge = DependencyGraph['edges'][number] & {
  required?: boolean;
  version_constraint?: string | null;
};

interface EdgeKindStyle {
  /** Human label used in the legend. */
  label: string;
  /** Themed stroke — CSS variable with a fallback, never a raw brand color. */
  stroke: string;
  /** Dashed strokes read as "soft" relationships (recommends / conflicts). */
  dashed: boolean;
}

const EDGE_KINDS: Record<string, EdgeKindStyle> = {
  requires: { label: 'requires', stroke: 'var(--color-info, #0284c7)', dashed: false },
  depends_on: { label: 'depends on', stroke: 'var(--color-border-focus, #3b82f6)', dashed: false },
  recommends: { label: 'recommends', stroke: 'var(--color-text-tertiary, #64748b)', dashed: true },
  conflicts: { label: 'conflicts', stroke: 'var(--color-error, #dc2626)', dashed: true },
  provides: { label: 'provides', stroke: 'var(--color-success, #16a34a)', dashed: false },
};

const UNKNOWN_EDGE_KIND: EdgeKindStyle = {
  label: 'related',
  stroke: 'var(--color-text-quaternary, #94a3b8)',
  dashed: true,
};

function edgeKind(type: string): EdgeKindStyle {
  return EDGE_KINDS[type] ?? { ...UNKNOWN_EDGE_KIND, label: type || UNKNOWN_EDGE_KIND.label };
}

// React Flow paints its own controls with hardcoded light colors; re-point them
// at the theme variables so the panel works in both light and dark.
const graphStyles = `
.composer-graph .react-flow__controls-button {
  background-color: var(--color-surface);
  border-color: var(--color-border);
  border-bottom-width: 1px;
  border-bottom-style: solid;
  fill: var(--color-text-primary);
  color: var(--color-text-primary);
}
.composer-graph .react-flow__controls-button:hover {
  background-color: var(--color-surface-hover);
}
.composer-graph .react-flow__controls-button svg {
  fill: var(--color-text-primary);
}
.composer-graph .react-flow__edge-text {
  fill: var(--color-text-secondary);
}
`;

function nodeStyle(explicit: boolean): React.CSSProperties {
  return {
    background: 'var(--color-surface, #ffffff)',
    color: 'var(--color-text-primary, #0f172a)',
    // Explicitly-chosen modules get a solid emphasis border; modules the
    // resolver pulled in get a dashed one, so operators can see what they
    // did not ask for directly.
    border: explicit
      ? '2px solid var(--color-border-focus, #3b82f6)'
      : '1px dashed var(--color-border-strong, #cbd5e1)',
    borderRadius: 6,
    padding: '6px 10px',
    fontSize: 11,
    width: 170,
    textAlign: 'center',
  };
}

export interface DependencyGraphPanelProps {
  graph?: DependencyGraph;
  /** Dim the canvas while a fresh compose_preview is in flight. */
  previewing?: boolean;
  height?: number;
}

export function DependencyGraphPanel({
  graph,
  previewing = false,
  height = 300,
}: DependencyGraphPanelProps): React.JSX.Element | null {
  const rawNodes = useMemo(() => (graph?.nodes ?? []) as GraphNode[], [graph]);
  const rawEdges = useMemo(() => (graph?.edges ?? []) as GraphEdge[], [graph]);

  const { nodes, edges } = useMemo(() => {
    if (rawNodes.length === 0) {
      return { nodes: [] as Node[], edges: [] as Edge[] };
    }

    const nodeIds = new Set(rawNodes.map((n) => n.id));

    const flowNodes: Node[] = rawNodes.map((n) => {
      // `explicit` is absent on older payloads — treat "unknown" as explicit so
      // nothing is falsely flagged as auto-resolved.
      const isExplicit = n.explicit ?? !n.auto_resolved;
      return {
        id: n.id,
        position: { x: 0, y: 0 },
        style: nodeStyle(isExplicit),
        data: {
          label: (
            <div className="leading-tight">
              <div className="font-medium truncate">{n.name}</div>
              <div className="text-theme-tertiary" style={{ fontSize: 10 }}>
                {n.variety}
                {isExplicit ? '' : ' · auto'}
              </div>
            </div>
          ),
        },
      };
    });

    const flowEdges: Edge[] = rawEdges
      .filter((e) => nodeIds.has(e.source) && nodeIds.has(e.target))
      .map((e, i) => {
        const kind = edgeKind(e.type);
        return {
          id: `${e.source}->${e.target}:${e.type}:${i}`,
          source: e.source,
          target: e.target,
          type: 'smoothstep',
          label: e.version_constraint || undefined,
          labelStyle: { fontSize: 10 },
          markerEnd: { type: MarkerType.ArrowClosed, color: kind.stroke },
          style: {
            stroke: kind.stroke,
            strokeWidth: kind.dashed ? 1.5 : 2,
            strokeDasharray: kind.dashed ? '6 4' : undefined,
          },
          data: { kind: e.type },
        };
      });

    const arranged = autoArrangeNodes(flowNodes, flowEdges, {
      direction: 'LR',
      nodeWidth: 170,
      nodeHeight: 56,
      spacing: 40,
    });

    return { nodes: arranged, edges: flowEdges };
  }, [rawNodes, rawEdges]);

  // Legend only lists the relationship kinds actually present in this payload.
  const legend = useMemo(() => {
    const seen = new Map<string, EdgeKindStyle>();
    rawEdges.forEach((e) => {
      if (!seen.has(e.type)) seen.set(e.type, edgeKind(e.type));
    });
    return Array.from(seen.entries());
  }, [rawEdges]);

  if (nodes.length === 0) return null;

  return (
    <section
      aria-label="Dependency graph"
      className="bg-theme-surface border border-theme rounded-lg overflow-hidden"
    >
      <div className="px-4 py-3 border-b border-theme flex flex-wrap items-center gap-x-4 gap-y-2 justify-between">
        <div className="flex items-center gap-2 text-sm font-medium">
          <Share2 size={14} className="text-theme-tertiary" />
          Dependency Graph
          <span className="text-xs font-normal text-theme-tertiary">
            {nodes.length} module{nodes.length === 1 ? '' : 's'} · {edges.length} link
            {edges.length === 1 ? '' : 's'}
            {previewing ? ' · previewing…' : ''}
          </span>
        </div>
        <ul className="flex flex-wrap items-center gap-3 text-xs text-theme-tertiary">
          {legend.map(([type, kind]) => (
            <li key={type} className="flex items-center gap-1.5">
              <span
                aria-hidden="true"
                style={{
                  display: 'inline-block',
                  width: 18,
                  height: 0,
                  borderTopWidth: 2,
                  borderTopStyle: kind.dashed ? 'dashed' : 'solid',
                  borderTopColor: kind.stroke,
                }}
              />
              {kind.label}
            </li>
          ))}
        </ul>
      </div>

      {edges.length === 0 && (
        <p className="px-4 pt-3 text-xs text-theme-tertiary">
          No declared relationships between these modules — each composes independently.
        </p>
      )}

      <div
        className="composer-graph"
        style={{ height, opacity: previewing ? 0.6 : 1 }}
        data-testid="dependency-graph-canvas"
      >
        <style>{graphStyles}</style>
        <ReactFlow
          nodes={nodes}
          edges={edges}
          fitView
          nodesDraggable
          nodesConnectable={false}
          elementsSelectable={false}
          proOptions={{ hideAttribution: true }}
        >
          <Background gap={16} size={1} />
          <Controls showInteractive={false} />
        </ReactFlow>
      </div>
    </section>
  );
}

export default DependencyGraphPanel;
