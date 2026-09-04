# frozen_string_literal: true

require "rails_helper"

# IMP-222dd9bce564 — the boot runner must SAY when a creation is a reversal.
#
# Permissions::RoleGrantReconciler now reports Result#recreated_grants: grants
# this deployment held whose rows were removed outside the catalog (a console
# Role#remove_permission, a migration's DELETE) and which the reconcile has just
# put back. That signal is worth nothing if the per-boot runner folds it into
# the same `created grant:` line it prints for a first-time creation — which is
# exactly what it did before. The runner is LOADED here against the real
# three-state sequence rather than grepped, so the assertion is on what the
# journal would actually contain.
#
# `type: :lib` is load-bearing — see role_grant_reconcile_wiring_spec.rb.
RSpec.describe "hub-backend role-grant reversal reporting (IMP-222dd9bce564)", type: :lib do
  runner = File.expand_path(
    "../../../modules/powernode-hub-backend/rootfs/usr/local/bin/role-grants-reconcile.rb", __dir__
  )

  let(:permission) { "spec.role_grant_reversal_wiring.widget" }
  let(:key) { "admin/#{permission}" }
  let(:admin_role) { Role.find_by!(name: "admin", account_id: nil) }

  before do
    create(:account) # the runner emits fleet events against Account.first
    Permissions.register_permissions(permission => "Spec-only permission")
    Permissions.register_role_permissions("admin", [ permission ])
    admin_role.role_permissions.where(permission_name: permission).delete_all
  end

  after do
    Permissions.extension_permissions.delete(permission)
    Permissions.extension_role_permissions["admin"].delete(permission)
  end

  def revoke!
    admin_role.role_permissions.where(permission_name: permission).delete_all
  end

  it "prints a plain `created grant:` line for a first-time creation, with no reversal marker" do
    expect { load runner }
      .to output(a_string_including("created grant: #{key}")
                 .and(satisfy { |s| !s.include?("RE-CREATED") }))
      .to_stderr
    expect(System::FleetEvent.where(kind: "role_grant_reversal")).not_to exist
  end

  it "prints a RE-CREATED line and emits a fleet event when a held grant was revoked outside the catalog" do
    # State 1 -> 2: first boot creates it (plain).
    expect { load runner }.to output(/created grant: #{Regexp.escape(key)}/).to_stderr

    # State 2 -> 3: an operator revokes it, then the next boot runs.
    revoke!
    expect { load runner }
      .to output(a_string_including("RE-CREATED grant (reversal): #{key}")
                 .and(a_string_including("recreated_grants=1")))
      .to_stderr

    # The signal outlives the journal, and the re-creation was NOT suppressed.
    event = System::FleetEvent.find_by(kind: "role_grant_reversal")
    expect(event).to be_present
    expect(event.payload["recreated_grants"]).to eq([ key ])
    expect(admin_role.reload.role_permissions.exists?(permission_name: permission)).to be(true)
  end

  it "reports the ledger as degraded rather than clean when it cannot be read" do
    # recreated_grants=0 with a broken ledger must not read as "no reversals".
    # A MALFORMED value is the reachable case — the row is editable through
    # Api::V1::SiteSettingsController#update — and it needs no stub, so this
    # exercises the real read path end to end rather than a mocked one.
    SiteSetting.create!(key: Permissions::RoleGrantReconciler::LEDGER_SETTING,
                        value: "{ not json", setting_type: "json", is_public: false)

    expect { load runner }.to output(/ledger unavailable \(reversal detection degraded\)/).to_stderr
  end

  it "tolerates a core Result that predates the reversal members (module skew)" do
    # hub-backend and the core tree are separate modules and can skew by one
    # deploy. Asserting that the runner's SOURCE mentions `respond_to?` would
    # pass for any body that merely names it — including one whose guard always
    # returned []. Hand the runner an OLD-SHAPED Result and read the journal.
    old_result = Struct.new(:created, :already_present, :created_grants,
                            :created_roles, :failed, keyword_init: true)
                       .new(created: 0, already_present: 7, created_grants: [],
                            created_roles: [], failed: [])
    allow_any_instance_of(Permissions::RoleGrantReconciler).to receive(:reconcile!).and_return(old_result)

    expect { load runner }
      .to output(a_string_including("recreated_grants=0")
                 .and(a_string_including("already_present=7"))
                 .and(satisfy { |s| !s.include?("unexpected error") }))
      .to_stderr
  end
end
