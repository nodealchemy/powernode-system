# frozen_string_literal: true

# System extension association for the core Worker model.
# Loaded by the PowernodeSystem engine via config.to_prepare decorator loading.
#
# Workers-as-NodeInstances (Stage 8b): each Sidekiq Worker is backed by a
# NodeInstance that carries its mTLS identity. The `node_instance_id`
# column lives on the core `workers` table (added by the migration in
# core), but the `belongs_to :node_instance` association can only be
# declared in the extension — core doesn't depend on extension models.
#
# Reverse side: NodeInstance#worker (zero-or-one) — at most one Sidekiq
# Worker per host, enforced by the unique index on workers.node_instance_id.
Worker.class_eval do
  belongs_to :node_instance,
             class_name:  "System::NodeInstance",
             foreign_key: :node_instance_id,
             optional:    true,
             inverse_of:  :worker
end

System::NodeInstance.class_eval do
  has_one :worker,
          class_name:  "::Worker",
          foreign_key: :node_instance_id,
          inverse_of:  :node_instance,
          dependent:   :nullify
end
