# frozen_string_literal: true

require "rails_helper"

# Regression for improvement 019f65bd: System::NodeArchitecture is a platform-wide
# catalog (deliberately NOT account-scoped, no account_id column). A stale
# `has_many :system_node_architectures` on Account queried the nonexistent
# system_node_architectures.account_id and crashed seeds / account teardown with
# PG::UndefinedColumn. Account must not own node_architectures.
RSpec.describe "Account ⇄ System::NodeArchitecture scoping", type: :model do
  it "System::NodeArchitecture has no account_id column (platform-wide catalog)" do
    expect(System::NodeArchitecture.column_names).not_to include("account_id")
  end

  it "Account does NOT declare a has_many association to system_node_architectures" do
    # A stale has_many (dependent: :restrict_with_error) here was what queried the
    # nonexistent account_id column on account teardown / seed passes.
    expect(Account.reflect_on_association(:system_node_architectures)).to be_nil
  end
end
