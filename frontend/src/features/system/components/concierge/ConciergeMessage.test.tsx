import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { ConciergeMessage, type ConciergeChatMessage } from './ConciergeMessage';

// Phase 10.7 polish — first test on the new system extension Jest infra.
describe('ConciergeMessage', () => {
  const baseMessage: ConciergeChatMessage = {
    id: 'm1',
    role: 'assistant',
    content: 'Hello',
    timestamp: '2026-05-04T08:00:00Z',
  };

  it('renders assistant content', () => {
    render(<ConciergeMessage message={baseMessage} />);
    expect(screen.getByText('Hello')).toBeInTheDocument();
  });

  it('renders user messages with right-justified styling', () => {
    const userMsg: ConciergeChatMessage = { ...baseMessage, id: 'u1', role: 'user', content: 'hi' };
    const { container } = render(<ConciergeMessage message={userMsg} />);
    // User messages are inside a flex container with justify-end
    expect(container.querySelector('.justify-end')).toBeInTheDocument();
    expect(container.querySelector('.justify-start')).not.toBeInTheDocument();
  });

  describe('CVE runbook action chips', () => {
    it('renders a runbook button for each CVE id mentioned in assistant content', () => {
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        content: 'Two open issues: CVE-2026-12345 (high) and CVE-2025-99999 (medium).',
      };
      render(<ConciergeMessage message={msg} onCveRunbookRequest={jest.fn()} />);

      const actions = screen.getByTestId('cve-runbook-actions');
      expect(actions).toBeInTheDocument();
      expect(screen.getByText('Runbook: CVE-2026-12345')).toBeInTheDocument();
      expect(screen.getByText('Runbook: CVE-2025-99999')).toBeInTheDocument();
    });

    it('deduplicates repeated CVE references', () => {
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        content: 'CVE-2026-12345 affects libfoo. Re: CVE-2026-12345 — see remediation plan.',
      };
      render(<ConciergeMessage message={msg} onCveRunbookRequest={jest.fn()} />);

      const buttons = screen.getAllByText(/Runbook: CVE-2026-12345/);
      expect(buttons).toHaveLength(1);
    });

    it('does not render runbook chips on user messages', () => {
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        role: 'user',
        content: 'How do I remediate CVE-2026-12345?',
      };
      render(<ConciergeMessage message={msg} onCveRunbookRequest={jest.fn()} />);

      expect(screen.queryByTestId('cve-runbook-actions')).not.toBeInTheDocument();
    });

    it('does not render chips when onCveRunbookRequest callback is missing', () => {
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        content: 'CVE-2026-12345 is open.',
      };
      render(<ConciergeMessage message={msg} />);

      expect(screen.queryByTestId('cve-runbook-actions')).not.toBeInTheDocument();
    });

    it('invokes the callback with the CVE id when a button is clicked', () => {
      const handler = jest.fn();
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        content: 'Fix CVE-2026-12345 first.',
      };
      render(<ConciergeMessage message={msg} onCveRunbookRequest={handler} />);

      fireEvent.click(screen.getByText('Runbook: CVE-2026-12345'));
      expect(handler).toHaveBeenCalledWith('CVE-2026-12345');
      expect(handler).toHaveBeenCalledTimes(1);
    });

    it('renders no chips when content has no CVE references', () => {
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        content: 'Everything is healthy. No CVEs at the moment.',
      };
      render(<ConciergeMessage message={msg} onCveRunbookRequest={jest.fn()} />);

      expect(screen.queryByTestId('cve-runbook-actions')).not.toBeInTheDocument();
    });
  });

  describe('tool messages', () => {
    it('renders tool name and arguments JSON', () => {
      const msg: ConciergeChatMessage = {
        ...baseMessage,
        role: 'tool',
        content: '',
        toolCall: {
          name: 'system_list_nodes',
          arguments: { limit: 10 },
          result: { count: 3 },
        },
      };
      render(<ConciergeMessage message={msg} />);

      expect(screen.getByText(/system_list_nodes/)).toBeInTheDocument();
      expect(screen.getByText(/"limit": 10/)).toBeInTheDocument();
      expect(screen.getByText(/"count": 3/)).toBeInTheDocument();
    });
  });
});
