import React from 'react';
import { render, screen } from '@testing-library/react';
import { DependencyGraphPanel } from './DependencyGraphPanel';
import type { TemplateComposePreview } from '@system/features/system/services/api/templatesApi';

// =============================================================================
// Mocks
//
// @xyflow/react needs real layout/measurement APIs that jsdom does not provide,
// so we swap ReactFlow for a sentinel that exposes what the panel handed it
// (node ids, edge stroke/dash per relationship kind). Same approach as
// SdwanTopology.test.tsx.
// =============================================================================

jest.mock('@xyflow/react', () => ({
  ReactFlow: ({
    nodes,
    edges,
    children,
  }: {
    nodes: Array<{ id: string; position: { x: number; y: number }; style?: Record<string, unknown> }>;
    edges: Array<{ id: string; style?: Record<string, unknown>; data?: Record<string, unknown> }>;
    children?: React.ReactNode;
  }) => (
    <div data-testid="react-flow">
      <span data-testid="node-count">{nodes.length}</span>
      <span data-testid="edge-count">{edges.length}</span>
      {nodes.map((n) => (
        <span
          key={n.id}
          data-testid={`rf-node-${n.id}`}
          data-position={`${n.position.x},${n.position.y}`}
          data-border={String(n.style?.border ?? '')}
        />
      ))}
      {edges.map((e) => (
        <span
          key={e.id}
          data-testid={`rf-edge-${String(e.data?.kind)}`}
          data-stroke={String(e.style?.stroke ?? '')}
          data-dash={String(e.style?.strokeDasharray ?? '')}
        />
      ))}
      {children}
    </div>
  ),
  Background: () => <div data-testid="rf-background" />,
  Controls: () => <div data-testid="rf-controls" />,
  MarkerType: { ArrowClosed: 'arrowclosed' },
}));

// =============================================================================
// Fixtures
// =============================================================================

type Graph = TemplateComposePreview['dependency_graph'];

const GRAPH: Graph = {
  nodes: [
    { id: 'mod-a', name: 'nginx', variety: 'instance' },
    { id: 'mod-b', name: 'openssl', variety: 'config' },
    { id: 'mod-c', name: 'telemetry', variety: 'config' },
  ],
  edges: [
    { source: 'mod-a', target: 'mod-b', type: 'requires' },
    { source: 'mod-a', target: 'mod-c', type: 'recommends' },
  ],
};

const EMPTY_GRAPH: Graph = { nodes: [], edges: [] };

// =============================================================================
// Tests
// =============================================================================

describe('DependencyGraphPanel', () => {
  it('renders nothing when the graph is undefined', () => {
    const { container } = render(<DependencyGraphPanel />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders nothing when the graph has no nodes', () => {
    const { container } = render(<DependencyGraphPanel graph={EMPTY_GRAPH} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders the canvas with one flow node per graph node', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.getByTestId('react-flow')).toBeInTheDocument();
    expect(screen.getByTestId('node-count')).toHaveTextContent('3');
    expect(screen.getByTestId('rf-node-mod-a')).toBeInTheDocument();
    expect(screen.getByTestId('rf-node-mod-b')).toBeInTheDocument();
    expect(screen.getByTestId('rf-node-mod-c')).toBeInTheDocument();
  });

  it('shows a header summarising module and link counts', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.getByText('Dependency Graph')).toBeInTheDocument();
    expect(screen.getByText(/3 modules · 2 links/)).toBeInTheDocument();
  });

  it('singularises the counts for a one-node, one-edge graph', () => {
    render(
      <DependencyGraphPanel
        graph={{
          nodes: [{ id: 'mod-a', name: 'nginx', variety: 'instance' }],
          edges: [{ source: 'mod-a', target: 'mod-a', type: 'requires' }],
        }}
      />
    );

    expect(screen.getByText(/1 module · 1 link/)).toBeInTheDocument();
  });

  it('runs the dagre layout so nodes do not all sit at the origin', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    const positions = ['mod-a', 'mod-b', 'mod-c'].map(
      (id) => screen.getByTestId(`rf-node-${id}`).getAttribute('data-position')
    );
    expect(new Set(positions).size).toBe(positions.length);
  });

  it('styles requires and recommends edges distinctly', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    const requires = screen.getByTestId('rf-edge-requires');
    const recommends = screen.getByTestId('rf-edge-recommends');

    expect(requires.getAttribute('data-stroke')).not.toEqual(
      recommends.getAttribute('data-stroke')
    );
    // requires is solid (no dash array), recommends is dashed
    expect(requires.getAttribute('data-dash')).toBe('');
    expect(recommends.getAttribute('data-dash')).toMatch(/\d/);
  });

  it('uses theme variables for edge strokes rather than raw colors', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.getByTestId('rf-edge-requires').getAttribute('data-stroke')).toMatch(
      /^var\(--color-/
    );
  });

  it('lists only the relationship kinds present in the payload', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.getByText('requires')).toBeInTheDocument();
    expect(screen.getByText('recommends')).toBeInTheDocument();
    expect(screen.queryByText('conflicts')).not.toBeInTheDocument();
    expect(screen.queryByText('provides')).not.toBeInTheDocument();
  });

  it('labels an unrecognised edge type with the raw type string', () => {
    render(
      <DependencyGraphPanel
        graph={{
          nodes: GRAPH.nodes,
          edges: [{ source: 'mod-a', target: 'mod-b', type: 'supersedes' }],
        }}
      />
    );

    expect(screen.getByText('supersedes')).toBeInTheDocument();
    expect(screen.getByTestId('rf-edge-supersedes')).toBeInTheDocument();
  });

  it('drops edges whose endpoints are not in the node set', () => {
    render(
      <DependencyGraphPanel
        graph={{
          nodes: GRAPH.nodes,
          edges: [
            { source: 'mod-a', target: 'mod-b', type: 'requires' },
            { source: 'mod-a', target: 'mod-missing', type: 'requires' },
          ],
        }}
      />
    );

    expect(screen.getByTestId('edge-count')).toHaveTextContent('1');
  });

  it('explains the empty-edge case instead of showing a bare canvas', () => {
    render(<DependencyGraphPanel graph={{ nodes: GRAPH.nodes, edges: [] }} />);

    expect(screen.getByText(/No declared relationships between these modules/)).toBeInTheDocument();
    expect(screen.getByTestId('node-count')).toHaveTextContent('3');
  });

  it('distinguishes auto-resolved modules from explicitly chosen ones', () => {
    render(
      <DependencyGraphPanel
        graph={{
          nodes: [
            { id: 'mod-a', name: 'nginx', variety: 'instance', explicit: true, auto_resolved: false },
            { id: 'mod-b', name: 'openssl', variety: 'config', explicit: false, auto_resolved: true },
          ],
          edges: [{ source: 'mod-a', target: 'mod-b', type: 'requires' }],
        } as Graph}
      />
    );

    const explicitBorder = screen.getByTestId('rf-node-mod-a').getAttribute('data-border');
    const autoBorder = screen.getByTestId('rf-node-mod-b').getAttribute('data-border');

    expect(explicitBorder).toContain('solid');
    expect(autoBorder).toContain('dashed');
  });

  it('treats nodes without explicit/auto_resolved flags as explicit', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.getByTestId('rf-node-mod-a').getAttribute('data-border')).toContain('solid');
  });

  it('flags an in-flight preview in the header', () => {
    render(<DependencyGraphPanel graph={GRAPH} previewing />);

    expect(screen.getByText(/previewing…/)).toBeInTheDocument();
  });

  it('does not claim to be previewing when idle', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.queryByText(/previewing…/)).not.toBeInTheDocument();
  });

  it('exposes an accessible region label', () => {
    render(<DependencyGraphPanel graph={GRAPH} />);

    expect(screen.getByRole('region', { name: 'Dependency graph' })).toBeInTheDocument();
  });
});
