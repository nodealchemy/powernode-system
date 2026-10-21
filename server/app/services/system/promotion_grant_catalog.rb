# frozen_string_literal: true

module System
  # The system extension's answer to core's `promotion_grant_catalog` seam
  # (Ai::PromotionGrants::Catalog): for release.promote — the category
  # system_promote_module_version gates on — which permission a granter must
  # hold, and which of this account's modules a grant may name.
  #
  # The permission is READ from the verb's own map rather than restated, so a
  # grant can never be issued by someone the verb itself would refuse.
  module PromotionGrantCatalog
    PROMOTE_ACTION = "system_promote_module_version"

    module_function

    def required_permission(category)
      return nil unless category.to_s == ::Ai::Tools::SystemFleetTool::RELEASE_PROMOTE_CATEGORY

      ::Ai::Tools::SystemFleetTool::ACTION_PERMISSIONS[PROMOTE_ACTION]
    end

    def subjects(account:, action_category:)
      return [] unless action_category.to_s == ::Ai::Tools::SystemFleetTool::RELEASE_PROMOTE_CATEGORY

      ::System::NodeModule.where(account_id: account.id).order(:name).pluck(:id, :name)
                          .map { |id, name| { id: id, name: name } }
    end

    def unknown_subject_ids(account:, action_category:, ids:)
      ids = Array(ids).map(&:to_s)
      return ids unless action_category.to_s == ::Ai::Tools::SystemFleetTool::RELEASE_PROMOTE_CATEGORY

      known = ::System::NodeModule.where(account_id: account.id, id: ids.grep(::Ai::PromotionGrant::UUID_FORMAT)).pluck(:id)
      ids - known
    end
  end
end
