# frozen_string_literal: true

# Operator-facing API for Sdwan::IpfixCollector. #create stands one up,
# #update toggles state (active/disabled), and #destroy deletes a collector.
#
# IMP-6bbe5c673c38 changed three things here.
#
# #create is NEW. Creation existed only on the AI surfaces — the
# SdwanIpfixCollectorComposeExecutor skill and the
# system_sdwan_create_ipfix_collector MCP action — so this route is the
# REST half of a verb split, not yet an operator-experience fix: no
# console screen posts to it yet (the SDWAN hub's IpfixCollectorsTab
# still points operators at the MCP action). It is GATED
# (Sdwan::Executors::CreateIpfixCollector performs the write), matching
# PortMappingsController#create: closing a parity gap by adding an
# UNGATED mutating verb would trade one defect for a worse one.
#
# #update and #destroy are now GATED TOO. That is the residual
# IMP-97c7b4123d8f recorded when it gated the MCP half of this family
# (db/seeds/system_sdwan_manager_agent.rb) and assigned to "the per-family
# parity tasks that own those controllers" — this is that task. Leaving
# them inline would have made the whole gate regime decorative: an
# operator who hardens sdwan.ipfix_collector_update to require_approval
# would get no protection at all, because the same JWT carrying
# system.sdwan.ipfix.manage performs the identical AASM transition one
# route over, outside Ai::AutonomyGate. A gate a caller can walk around
# is not a gate.
#
# The console already speaks the gated shape for both verbs, so this is
# not a behaviour change it has to learn: sdwanApi.setIpfixCollectorState
# and .deleteIpfixCollector already return Gated<T> through extractGated,
# and IpfixCollectorsTab already renders pendingApprovalNotice on the
# :pending branch. On a seeded account both resolve to notify_and_proceed
# / require_approval respectively — the tiers the MCP twins have carried
# since IMP-97c7b4123d8f — so the two surfaces now answer alike.
#
# Each row carries an `is_winning_collector` flag in the serialized
# shape: the topology compiler picks the account's oldest active
# collector when stamping the ipfix payload onto OVS bridges, so a
# fleet can have multiple collectors but only one wires up. Surfacing
# the flag here lets operators see at a glance which row will
# actually be used.
#
# Phase O6 of the OVS+OVN dual-profile networking roadmap.
module Api
  module V1
    module System
      module Sdwan
        class IpfixCollectorsController < ::Api::V1::System::BaseController
          include ::System::GatedActions

          before_action :set_account
          before_action :set_collector, only: %i[show update destroy]

          def index
            require_permission("system.sdwan.ipfix.read")

            scope = ::Sdwan::IpfixCollector.for_account(@account)
            scope = scope.where(state: params[:state]) if params[:state].present?

            collectors = scope.order(:created_at).to_a
            winning_id = winning_collector_id

            render_success(
              ipfix_collectors: collectors.map { |c| serialize_collector(c, winning_id: winning_id) },
              count: collectors.size,
              filters: { state: params[:state] }.compact
            )
          end

          def show
            require_permission("system.sdwan.ipfix.read")
            render_success(ipfix_collector: serialize_collector_full(@collector))
          end

          # Response contract, the same one every gated SDWAN create carries:
          # on :proceed the answer is 201 with the serialized row; on
          # :pending it is 202 with a deferred_operation_id and the row
          # appears only at approval time, because gate! never calls
          # on_proceed on :pending. Which branch an operator gets is a
          # per-account policy question — gate! passes no `agent:`, and
          # db/seeds/system_sdwan_manager_agent.rb seeds the per-verb table
          # onto agent-less rows too (IMP-187124ca2984), so a seeded account
          # resolves sdwan.ipfix_collector_create to notify_and_proceed and
          # lands on :proceed.
          def create
            require_permission("system.sdwan.ipfix.manage")

            attrs = collector_params.to_h
            # Never saved — the executor's create! stays the authority.
            # Defaults AND the .to_i coercion are applied here as well as in
            # the executor, so the pre-gate validation sees the row the
            # executor will actually build. Both halves matter: without the
            # defaults this 422s on a nil port the executor would have filled
            # in, and without the coercion "4739x" is refused here but
            # accepted (as 4739) by the MCP twin, which builds its candidate
            # with the same .to_i. One payload, one answer, both surfaces.
            candidate = ::Sdwan::IpfixCollector.new(
              account_id: @account.id,
              name: attrs["name"],
              host: attrs["host"],
              port: attrs["port"].present? ? attrs["port"].to_i : 4739,
              sampling_rate: attrs["sampling_rate"].present? ? attrs["sampling_rate"].to_i : 1
            )

            gate_create!(
              candidate: candidate,
              scope: ::Sdwan::IpfixCollector.for_account(@account),
              result_key: :collector_id,
              response_key: :ipfix_collector,
              serializer: ->(c) { serialize_collector_full(c) },
              action_category: ::Sdwan::Executors::CreateIpfixCollector::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::CreateIpfixCollector",
              params: {
                name: attrs["name"], host: attrs["host"],
                port: attrs["port"], sampling_rate: attrs["sampling_rate"]
              },
              description: "Create IPFIX collector #{candidate.name}"
            )
          end

          # Shaped on VirtualIpsController#failover, the controller family's
          # other gated state transition: refuse an impossible request FIRST,
          # then hand the transition itself to the executor through a bare
          # gate!. gate_update! is the wrong helper here — it exists to
          # assign-validate-reload caller ATTRIBUTES, and this verb fires an
          # AASM event rather than writing a field.
          #
          # Refusing before the gate is the same contract the MCP twin keeps:
          # an impossible request must fail now, not sit in an operator's
          # queue until they approve it and watch it fail. The wording is
          # shared verbatim with Ai::Tools::SdwanTool#update_ipfix_collector,
          # so the two surfaces naming one operation cannot disagree.
          def update
            require_permission("system.sdwan.ipfix.manage")

            target = (params.dig(:ipfix_collector, :state) || params[:state]).to_s
            unless ::Sdwan::IpfixCollector::STATES.include?(target)
              return render_error("state must be 'active' or 'disabled'", status: :unprocessable_content)
            end

            permitted = target == "active" ? @collector.may_enable? : @collector.may_disable?
            unless permitted
              return render_error("cannot move IPFIX collector from #{@collector.state} to #{target}",
                                  status: :unprocessable_content)
            end

            gate!(
              action_category: ::Sdwan::Executors::UpdateIpfixCollector::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::UpdateIpfixCollector",
              params: { collector_id: @collector.id, state: target },
              source_type: "Sdwan::IpfixCollector",
              source_id: @collector.id,
              description: "Set IPFIX collector #{@collector.name.presence || @collector.id} to #{target}",
              on_proceed: ->(_r) { render_success(ipfix_collector: serialize_collector_full(@collector.reload)) }
            )
          end

          # The id is captured BEFORE the gate: on the :proceed branch the row
          # is gone by the time on_proceed runs, and reading it off the
          # destroyed instance is the kind of thing that works until the
          # executor stops returning one.
          def destroy
            require_permission("system.sdwan.ipfix.manage")

            id = @collector.id
            gate!(
              action_category: ::Sdwan::Executors::DeleteIpfixCollector::ACTION_CATEGORY,
              executor_class: "Sdwan::Executors::DeleteIpfixCollector",
              params: { collector_id: id },
              source_type: "Sdwan::IpfixCollector",
              source_id: id,
              description: "Delete IPFIX collector #{@collector.name.presence || id}",
              on_proceed: ->(_r) { render_success(deleted: true, id: id) }
            )
          end

          private

          def collector_params
            params.require(:ipfix_collector).permit(:name, :host, :port, :sampling_rate)
          end

          def set_collector
            @collector = ::Sdwan::IpfixCollector.where(account_id: @account.id)
                                                .find(params[:id])
          rescue ActiveRecord::RecordNotFound
            render_not_found("SDWAN IPFIX Collector")
          end

          # Computed once per request — index walks every collector but
          # the winner lookup runs once. O(n+1) to O(n+1) tradeoff is
          # fine since n is tiny (operators rarely run >5 collectors).
          def winning_collector_id
            @winning_collector_id ||=
              ::Sdwan::IpfixCollector.for_account(@account).active.order(:created_at).first&.id
          end

          def serialize_collector(c, winning_id:)
            {
              id: c.id,
              name: c.name,
              host: c.host,
              port: c.port,
              target_endpoint: c.target_endpoint,
              sampling_rate: c.sampling_rate,
              state: c.state,
              is_winning_collector: c.id == winning_id
            }
          end

          def serialize_collector_full(c)
            serialize_collector(c, winning_id: winning_collector_id).merge(
              created_at: c.created_at.iso8601,
              updated_at: c.updated_at.iso8601
            )
          end
        end
      end
    end
  end
end
