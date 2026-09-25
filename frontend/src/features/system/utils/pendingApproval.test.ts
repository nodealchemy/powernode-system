import type { PendingApproval } from '../services/api/helpers';
import { APPROVALS_SURFACE_PATH, pendingApprovalNotice } from './pendingApproval';

const PENDING: PendingApproval = {
  pending: true,
  deferred_operation_id: 'dop-1',
  action_category: 'sdwan.port_mapping_delete',
  approval_request_id: 'ar-1',
  message: 'Approval required: sdwan.port_mapping_delete',
};

describe('pendingApprovalNotice', () => {
  it('builds an info notification naming the subject and linking to the approvals surface with its request id', () => {
    const notice = pendingApprovalNotice("deleting port mapping 'web-443'", PENDING);

    expect(notice.type).toBe('info');
    expect(notice.message).toContain("deleting port mapping 'web-443'");
    expect(notice.message).toMatch(/approval required/i);
    expect(notice.message).toMatch(/no change has been applied/i);
    expect(notice.link).toEqual({
      label: 'Review approvals',
      to: `${APPROVALS_SURFACE_PATH}?request=ar-1`,
    });
  });

  it('links to the bare approvals surface when the gate returned no request id', () => {
    const notice = pendingApprovalNotice('deleting the thing', {
      ...PENDING,
      approval_request_id: null,
    });

    expect(notice.link).toEqual({ label: 'Review approvals', to: APPROVALS_SURFACE_PATH });
  });

  it('carries the approval ids in the expandable details', () => {
    const notice = pendingApprovalNotice('deleting the thing', PENDING);

    expect(notice.details).toMatchObject({
      action: 'sdwan.port_mapping_delete',
      approval_request_id: 'ar-1',
      deferred_operation_id: 'dop-1',
    });
  });

  it('omits approval_request_id from details when the gate returned none', () => {
    const notice = pendingApprovalNotice('deleting the thing', {
      ...PENDING,
      approval_request_id: null,
    });

    expect(notice.details).not.toHaveProperty('approval_request_id');
    expect(notice.details).toMatchObject({ deferred_operation_id: 'dop-1' });
  });
});

// The link must name the approval queue's own URL: core's AI → Control →
// Approvals → Queue tab. A leaf-index URL would redirect and drop ?request=.
describe('APPROVALS_SURFACE_PATH', () => {
  it('is the Control approval queue', () => {
    expect(APPROVALS_SURFACE_PATH).toBe('/app/ai/control/approvals/queue');
  });
});
