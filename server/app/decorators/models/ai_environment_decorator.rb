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
