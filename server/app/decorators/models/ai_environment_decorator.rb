# frozen_string_literal: true

# System extension associations for the core Ai::Environment model
# (Environment campaign, increment 1). Loaded by the PowernodeSystem engine's
# decorator loader, like account_decorator.rb.
#
# === dependent: :restrict_with_error ===
# An environment with fleet rows in it cannot be destroyed, and neither can
# the account that owns it: core's `Account has_many :environments,
# dependent: :destroy` calls destroy on each environment, which refuses here,
# so the account teardown stops at the same clean refusal the fleet
# associations on Account already give it — instead of an FK violation from
# the database.
Ai::Environment.class_eval do
  has_many :system_node_templates, class_name: "System::NodeTemplate", foreign_key: :environment_id,
                                   dependent: :restrict_with_error, inverse_of: :environment
  has_many :system_nodes, class_name: "System::Node", foreign_key: :environment_id,
                          dependent: :restrict_with_error, inverse_of: :environment
  has_many :system_node_instances, class_name: "System::NodeInstance", foreign_key: :environment_id,
                                   dependent: :restrict_with_error, inverse_of: :environment
  has_many :system_instance_pools, class_name: "System::InstancePool", foreign_key: :environment_id,
                                   dependent: :restrict_with_error, inverse_of: :environment
  has_many :system_federation_peers, class_name: "System::FederationPeer", foreign_key: :environment_id,
                                     dependent: :restrict_with_error, inverse_of: :environment
end

# Pre-flight for Account teardown (Account.register_teardown_guard): refuse
# BEFORE the teardown has any side effect while fleet rows still live in one of
# the account's environments, instead of discovering it mid-cascade when the
# environment's own restrict_with_error fires. Only this extension's own
# associations: core's (projects) are destroyed first by the teardown itself.
# `covers:` tells the FK coverage spec that every column of these tables is
# safe because the teardown refuses while such rows exist.
system_fleet_reflections = lambda do
  Ai::Environment.reflect_on_all_associations.select do |r|
    r.options[:dependent] == :restrict_with_error && r.options[:class_name].to_s.start_with?("System::")
  end
end

Account.register_teardown_guard(:system_environment_fleet,
                                covers: system_fleet_reflections.call.map { |r| [ r.klass.table_name, "*" ] }) do |account|
  system_fleet_reflections.call
                          .select { |r| r.klass.where(r.foreign_key => Ai::Environment.where(account_id: account.id).select(:id)).exists? }
                          .map { |r| "Cannot delete account with existing #{r.name.to_s.humanize.downcase} in its environments" }
end
