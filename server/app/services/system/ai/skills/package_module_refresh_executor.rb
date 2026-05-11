# frozen_string_literal: true

module System
  module Ai
    module Skills
      # Skill executor for refreshing a NodeModule when its source package
      # version drifts upstream. Triggered by PackageDriftSensor.
      #
      # Approval policy:
      #   * CVE-flagged refresh → auto-approve (4h cooldown)
      #   * Non-CVE drift refresh → human approval required
      # The CVE check happens in the Fleet Autonomy intervention policy
      # layer, not here — this executor unconditionally enqueues; the
      # autonomy framework gates whether the enqueue is allowed.
      class PackageModuleRefreshExecutor
        def self.descriptor
          {
            name:        "package_module_refresh",
            description: "Re-materialize a NodeModule's source package when upstream drifts (replays persisted recommends_chosen for determinism)",
            category:    "devops",
            inputs: {
              package_module_link_id: { type: "string", required: true,
                                        description: "PackageModuleLink.id of the module to refresh" },
              force:                  { type: "boolean", required: false }
            },
            outputs: {
              enqueued:               :boolean,
              package_module_link_id: :string
            }
          }
        end

        def initialize(account:, agent: nil, user: nil)
          @account = account
          @agent   = agent
          @user    = user
        end

        def execute(package_module_link_id:, force: false)
          link = ::System::PackageModuleLink
                   .joins(:node_module)
                   .where(system_node_modules: { account_id: @account.id })
                   .find_by(id: package_module_link_id)
          return failure("link not found or not accessible") unless link

          if defined?(SystemPackageModuleRefreshJob)
            SystemPackageModuleRefreshJob.perform_async(link.id, !!force)
          end
          success(
            enqueued:               true,
            package_module_link_id: link.id,
            requires_approval:      false
          )
        end

        private

        def success(**data); { success: true, data: data }; end
        def failure(msg); { success: false, error: msg }; end
      end
    end
  end
end
