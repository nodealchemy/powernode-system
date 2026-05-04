# frozen_string_literal: true

# Sdwan::RoutePolicy — declarative iBGP route policies. Three scopes
# (account, network, peer) compose at compile time; each carries an
# ordered list of {match: {...}, action: {...}} statements that the
# Sdwan::Bgp::RoutePolicyCompiler translates into FRR route-map syntax.
#
# scope_resource_id is null for scope=account (the policy applies
# everywhere); set to the Sdwan::Network.id for scope=network; set to
# the Sdwan::Peer.id for scope=peer. The compiler resolves all three
# levels per-peer at compile time so multi-tier policies are a single
# add to FRR's route-map chain.
#
# Slice 9e of the SDWAN plan.
class CreateSdwanRoutePolicies < ActiveRecord::Migration[8.1]
  def change
    create_table :sdwan_route_policies, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: true

      t.string :name, null: false, limit: 64
      t.string :description, limit: 255

      # account | network | peer — narrowing scope; compiler unions all
      # applicable rows at per-peer compile time.
      t.string :scope, null: false, default: "account"

      # Null when scope=account; references Sdwan::Network.id when
      # scope=network; references Sdwan::Peer.id when scope=peer. We
      # don't add an FK constraint because the column points at two
      # different tables depending on scope.
      t.uuid :scope_resource_id

      # import | export — drives whether the route-map applies to
      # inbound or outbound neighbor traffic.
      t.string :direction, null: false

      # Ordered list of statements. Schema enforced at the model level:
      #   [
      #     { "match": { "prefix_in": ["10.0.0.0/24"] },
      #       "action": { "type": "accept", "set_local_pref": 200 } },
      #     { "match": { "as_path_regex": "^4200000000$" },
      #       "action": { "type": "reject" } }
      #   ]
      t.jsonb :statements, null: false, default: []

      t.boolean :enabled, null: false, default: true
      t.jsonb :metadata, default: {}, null: false

      t.timestamps
    end

    add_index :sdwan_route_policies, %i[account_id name], unique: true
    add_index :sdwan_route_policies, %i[account_id scope]
    add_index :sdwan_route_policies, %i[scope scope_resource_id]
    add_check_constraint :sdwan_route_policies,
                         "scope IN ('account', 'network', 'peer')",
                         name: "sdwan_route_policies_scope_enum"
    add_check_constraint :sdwan_route_policies,
                         "direction IN ('import', 'export')",
                         name: "sdwan_route_policies_direction_enum"
  end
end
