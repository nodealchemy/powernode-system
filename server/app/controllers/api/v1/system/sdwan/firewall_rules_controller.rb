# frozen_string_literal: true

# Operator-facing CRUD for Sdwan::FirewallRule. Nested under networks —
# each rule belongs to exactly one network. The compiler is consulted on
# show/update so operators get an immediate preview of the nft fragment
# their rule generates without having to wait for the next agent reconcile.
#
# Slice 2 of the SDWAN plan.
module Api
  module V1
    module System
      module Sdwan
        class FirewallRulesController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_network
          before_action :set_rule, only: %i[show update destroy]

          def index
            require_permission("system.sdwan.firewall.read")
            rules = @network.firewall_rules.ordered
            rules = rules.where(enabled: params[:enabled]) if params.key?(:enabled)
            render_success(
              firewall_rules: rules.map { |r| serialize_rule(r) },
              count: rules.size,
              network_default_policy: ::Sdwan::FirewallCompiler.new(@network).default_policy
            )
          end

          def show
            require_permission("system.sdwan.firewall.read")
            render_success(firewall_rule: serialize_rule_full(@rule))
          end

          # IMP-6c482005db87: routed through Ai::AutonomyGate.
          # Sdwan::Executors::CreateFirewallRule existed, tenancy-hardened and
          # card-labeled, but had no caller — this wrote the nftables rule
          # inline behind the permission check, so the seeded
          # sdwan.firewall_rule_create policy matched nothing an operator did,
          # while DELETE below has been gated since slice 2.
          #
          # Same response contract as PortMappingsController#create
          # (IMP-bf996c7abcb4): validated before the gate so an unsaveable
          # payload keeps its field-level 422 and opens no audit row; 202 with
          # the deferred-operation id on :pending (the executor — never this
          # controller — performs the write, since gate! does not call
          # on_proceed on :pending); 201 with the serialized row on :proceed
          # (seeded accounts carry the agent-less notify_and_proceed operator
          # row, IMP-187124ca2984).
          def create
            require_permission("system.sdwan.firewall.manage")
            attrs = rule_params

            # Never saved — the executor's create! stays the authority.
            candidate = @network.firewall_rules.new(account_id: @account.id)
            assign_with_port_range(candidate, attrs)
            return render_validation_error(candidate) unless candidate.valid?

            gate!(
              action_category: "sdwan.firewall_rule_create",
              executor_class: "Sdwan::Executors::CreateFirewallRule",
              params: { network_id: @network.id, attributes: executor_rule_attributes(attrs) },
              source_type: "Sdwan::Network",
              source_id: @network.id,
              # Matches CreateFirewallRule#summarize so both surfaces of the
              # approval speak one sentence (IMP-3a563becb7d7).
              description: "Add firewall rule '#{candidate.name}' to SDWAN network #{@network.name}",
              on_proceed: lambda { |result|
                created = @network.firewall_rules.find(result.result&.dig(:data, :rule_id))
                render_success({ firewall_rule: serialize_rule_full(created) }, status: :created)
              }
            )
          end

          def update
            require_permission("system.sdwan.firewall.manage")
            attrs = rule_params
            assign_with_port_range(@rule, attrs)
            if @rule.save
              render_success(firewall_rule: serialize_rule_full(@rule.reload))
            else
              render_validation_error(@rule)
            end
          end

          def destroy
            require_permission("system.sdwan.firewall.manage")
            id = @rule.id
            gate!(
              action_category: "sdwan.firewall_rule_delete",
              executor_class: "Sdwan::Executors::DeleteFirewallRule",
              params: { rule_id: id },
              source_type: "Sdwan::FirewallRule",
              source_id: id,
              description: "Delete firewall rule #{@rule.try(:name) || id}",
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          private

          def set_network
            @network = ::Sdwan::Network.where(account_id: @account.id).find(params[:network_id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Network")
          end

          def set_rule
            @rule = @network.firewall_rules.find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN Firewall Rule")
          end

          def rule_params
            params.require(:firewall_rule).permit(
              :name, :priority, :action, :direction, :protocol, :enabled,
              src_selector: {}, dst_selector: {}, port_range: %i[from to]
            )
          end

          # The :port_range param uses {from:, to:} JSON shape — re-key it to
          # the model's mass-assignable port_range_hash accessor (the raw
          # column is an int4range a Hash cannot set). ONE normalization for
          # both consumers: model assignment (candidate + update) and the
          # executor replay hash (IMP-6c482005db87).
          def normalize_port_range(attrs)
            attrs = attrs.to_h.with_indifferent_access
            port_range = attrs.delete(:port_range)
            attrs[:port_range_hash] = port_range unless port_range.nil?
            attrs
          end

          def assign_with_port_range(rule, attrs)
            rule.assign_attributes(normalize_port_range(attrs))
          end

          # account_id rides along ONLY for the approval card's scoped
          # network label (Base.preview runs with deferred_operation: nil);
          # Base#attrs strips it again before the executor's create!.
          def executor_rule_attributes(attrs)
            normalize_port_range(attrs).merge(account_id: @account.id)
          end

          def serialize_rule(r)
            {
              id: r.id,
              network_id: r.sdwan_network_id,
              name: r.name,
              priority: r.priority,
              action: r.action,
              direction: r.direction,
              protocol: r.protocol,
              src_selector: r.src_selector,
              dst_selector: r.dst_selector,
              port_range: r.port_range_hash,
              enabled: r.enabled
            }
          end

          def serialize_rule_full(r)
            serialize_rule(r).merge(
              compiled_preview: preview_rule(r),
              metadata: r.metadata,
              last_compiled_at: r.last_compiled_at&.iso8601,
              created_at: r.created_at.iso8601
            )
          end

          # Single-rule nft preview — operator sees the literal line their
          # rule would produce. Cheap enough to compute on every show/update.
          def preview_rule(rule)
            return nil unless rule.persisted?

            compiler = ::Sdwan::FirewallCompiler.new(@network)
            compiler.send(:emit_rule, rule)
          end
        end
      end
    end
  end
end
