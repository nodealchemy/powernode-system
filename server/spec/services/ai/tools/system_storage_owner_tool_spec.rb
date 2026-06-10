# frozen_string_literal: true

require "rails_helper"

# F8-02: ACTION_PERMISSIONS mapped the mutating storage-owner actions to
# "system.storage.update", which has no Permission record (the live storage
# taxonomy is system.storage.assignments.* / system.storage.mount_points.*),
# so non-super-admins were permanently denied owner assignment + chown retry.
RSpec.describe Ai::Tools::SystemStorageOwnerTool do
  describe "delegation-action permission slugs" do
    let(:account) { create(:account) }
    let(:operator) { create(:user, account: account, permissions: %w[system.storage.assignments.update]) }
    let(:tool) { described_class.new(account: account, user: operator) }

    %w[system_assign_storage_owner system_storage_chown_retry].each do |action|
      it "permits #{action} for a holder of system.storage.assignments.update" do
        expect(tool.send(:action_permitted?, action)).to be true
      end
    end
  end
end
