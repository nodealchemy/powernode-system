import React from 'react';
import { render, screen } from '@testing-library/react';
import { BootEventDetailPanel } from './BootEventDetailPanel';
import type { BootEvent } from '../../../services/api/bootReplayApi';

describe('BootEventDetailPanel', () => {
  it('renders the empty-state message when event is null', () => {
    render(<BootEventDetailPanel event={null} />);
    expect(screen.getByText('Select an event to view its payload.')).toBeInTheDocument();
  });

  it('renders kind, severity, source when event is provided', () => {
    const event: BootEvent = {
      id: 'evt-1',
      kind: 'kernel.module_loaded',
      severity: 'low',
      payload: { module: 'overlay' },
      emitted_at: '2026-05-04T10:00:00Z',
      correlation_id: 'corr-123',
      source: 'agent',
    };
    render(<BootEventDetailPanel event={event} />);

    expect(screen.getByText('kernel.module_loaded')).toBeInTheDocument();
    expect(screen.getByText('low')).toBeInTheDocument();
    expect(screen.getByText('agent')).toBeInTheDocument();
    expect(screen.getByText('corr-123')).toBeInTheDocument();
  });

  it('renders payload as formatted JSON', () => {
    const event: BootEvent = {
      id: 'evt-2',
      kind: 'systemd.service_started',
      severity: 'low',
      payload: { service: 'powernode-agent', uptime_ms: 3200 },
      emitted_at: '2026-05-04T10:00:00Z',
    };
    render(<BootEventDetailPanel event={event} />);

    expect(screen.getByText(/"service": "powernode-agent"/)).toBeInTheDocument();
    expect(screen.getByText(/"uptime_ms": 3200/)).toBeInTheDocument();
  });

  it('falls back to em-dash for missing source / correlation_id', () => {
    const event: BootEvent = {
      id: 'evt-3',
      kind: 'enrollment.received',
      severity: 'medium',
      payload: {},
      emitted_at: '2026-05-04T10:00:00Z',
    };
    render(<BootEventDetailPanel event={event} />);

    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(2);
  });

  it('renders the emitted timestamp in ISO format', () => {
    const event: BootEvent = {
      id: 'evt-4',
      kind: 'firmware.uefi_boot',
      severity: 'low',
      payload: {},
      emitted_at: '2026-05-04T10:00:00Z',
    };
    render(<BootEventDetailPanel event={event} />);

    // Check that the ISO timestamp pattern (YYYY-MM-DD...Z) is present
    const allMonoElements = screen.getAllByText(/2026-05-04T/);
    expect(allMonoElements.length).toBeGreaterThan(0);
  });
});
