# frozen_string_literal: true

module Sdwan
  # Defense-in-depth for approval-card message integrity (IMP-acb2e40960e7):
  # SDWAN names resurface verbatim in LATER unrelated approval cards
  # (delete/update previews render the persisted name), and the cards are
  # line-structured — so a name carrying vertical whitespace persisted via
  # ANY create path would keep forging card lines indefinitely, which is why
  # per-executor sanitization cannot close the hole. The card composer
  # (Ai::DeferredOperationApprovalContent.collapse_lines) collapses line
  # structure centrally at render time; this validation keeps such names out
  # of the tables in the first place. The regex duplicates the composer's on
  # purpose: core cannot depend on this extension, and the two layers must
  # each hold alone. Verified before adding: no existing rows violate
  # (all four tables empty in dev + test, 2026-08-14).
  module LineSafeName
    extend ActiveSupport::Concern

    LINE_BREAKS = Regexp.new("[\\r\\n\\v\\f\\u0085\\u2028\\u2029]")

    included do
      validates :name, format: { without: LINE_BREAKS, message: "cannot contain line breaks" }
    end
  end
end
