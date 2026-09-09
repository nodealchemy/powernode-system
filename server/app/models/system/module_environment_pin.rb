# frozen_string_literal: true

module System
  # The version an ENVIRONMENT runs of a module (Environment campaign,
  # increment 4). Only pinned environments (Ai::Environment#follows_publish?
  # false) carry rows; a following environment serves NodeModule#current_version.
  # Written by NodeModule#promote_in_environment! / #rollback_in_environment!
  # (ladder steps) and PromotionModeListener (the freeze that pins every module
  # where it stands the moment an environment is flipped to pinned). A pinned
  # environment with NO pin for a module serves nothing of it.
  class ModuleEnvironmentPin < BaseRecord
    belongs_to :account
    belongs_to :node_module, class_name: "System::NodeModule", inverse_of: :environment_pins
    belongs_to :environment, class_name: "Ai::Environment"
    belongs_to :node_module_version, class_name: "System::NodeModuleVersion"

    validates :environment_id, uniqueness: { scope: :node_module_id }
    validate :rows_share_one_account
    validate :version_belongs_to_module

    scope :for_environment, ->(env) { where(environment_id: env.is_a?(::Ai::Environment) ? env.id : env) }

    # Answers core's `environment_promotion_mode_listener` seam: when an
    # environment flips to PINNED, freeze every module at the version its
    # nodes are running (current_version) so nothing changes until a
    # promotion; when it flips back to FOLLOWING, its pins are meaningless
    # (a following plane serves current_version) and are dropped.
    module PromotionModeListener
      def self.call(environment:)
        if environment.follows_publish?
          ::System::ModuleEnvironmentPin.where(environment_id: environment.id).delete_all
        else
          freeze!(environment)
        end
      end

      def self.freeze!(environment)
        ::System::NodeModule.where(account_id: environment.account_id).where.not(current_version_id: nil)
                            .where.not(id: ::System::ModuleEnvironmentPin.where(environment_id: environment.id).select(:node_module_id))
                            .find_each do |mod|
          ::System::ModuleEnvironmentPin.create!(account_id: mod.account_id, node_module: mod, environment: environment,
                                                 node_module_version_id: mod.current_version_id,
                                                 promoted_by_type: "pin_freeze", promoted_at: Time.current)
        end
      end
    end

    private

    def rows_share_one_account
      return if account_id.nil?

      errors.add(:node_module, "must belong to the pin's account") if node_module && node_module.account_id != account_id
      errors.add(:environment, "must belong to the pin's account") if environment && environment.account_id != account_id
    end

    def version_belongs_to_module
      return if node_module_version.nil? || node_module.nil?
      return if node_module_version.node_module_id == node_module.id

      errors.add(:node_module_version, "belongs to a different module")
    end
  end
end
