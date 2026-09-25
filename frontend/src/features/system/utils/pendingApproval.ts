// Pending-approval toast shape (IMP-87ec6f651f07).
//
// Gated SDWAN mutations answer 202 `{pending: true, ...}` when the autonomy
// gate parks them for approval. Every call site in the sdwan / sdwan_hub
// component trees renders the SAME notification for that branch: an info
// toast that names the parked operation, carries the approval ids in the
// expandable details, and links to the approvals surface — never a success
// toast, because nothing has been applied yet.

import type { PendingApproval } from '../services/api/helpers';

/**
 * Route of the operator approvals surface: core's AI → Control → Approvals →
 * Queue tab, which lists pending `Ai::ApprovalRequest` rows. It is the tab's
 * own URL, not the Approvals leaf, because the leaf's index redirect would
 * drop a `?request=` deep link.
 */
export const APPROVALS_SURFACE_PATH = '/app/ai/control/approvals/queue';

export interface PendingApprovalNotice {
  type: 'info';
  message: string;
  details: Record<string, unknown>;
  link: { label: string; to: string };
}

/**
 * Build the one-shape pending-approval notification.
 *
 * @param subject operation phrase naming the subject, lowercase verb-first —
 *   e.g. `deleting port mapping 'web-443'`, `revoking access grant`.
 */
export function pendingApprovalNotice(
  subject: string,
  pending: PendingApproval
): PendingApprovalNotice {
  const details: Record<string, unknown> = { action: pending.action_category };
  if (pending.approval_request_id) {
    details.approval_request_id = pending.approval_request_id;
  }
  details.deferred_operation_id = pending.deferred_operation_id;
  // Named, not just landed on the section: the queue reads this id off the
  // URL and expands that row, so the operator does not have to hunt for it
  // among every other pending request.
  const linkTo = pending.approval_request_id
    ? `${APPROVALS_SURFACE_PATH}?request=${encodeURIComponent(pending.approval_request_id)}`
    : APPROVALS_SURFACE_PATH;
  return {
    type: 'info',
    message: `Approval required: ${subject} is awaiting review — no change has been applied yet.`,
    details,
    link: { label: 'Review approvals', to: linkTo },
  };
}
