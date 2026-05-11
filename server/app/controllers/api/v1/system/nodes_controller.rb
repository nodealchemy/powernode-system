# frozen_string_literal: true

module Api
  module V1
    module System
      class NodesController < BaseController
        before_action :set_account
        before_action :set_node, only: [ :show, :update, :destroy, :apply_template ]

        def index
          require_permission("system.nodes.read")
          nodes = @account.system_nodes.includes(:node_template, :worker)
          nodes = apply_filters(nodes)
          nodes = paginate(nodes)
          render_success(nodes: serialize_collection(nodes), meta: pagination_meta)
        end

        def show
          require_permission("system.nodes.read")
          render_success(node: serialize_node(@node))
        end

        def create
          require_permission("system.nodes.create")
          node = @account.system_nodes.build(node_params)

          if node.save
            render_success(node: serialize_node(node), status: :created)
          else
            render_validation_error(node)
          end
        end

        def update
          require_permission("system.nodes.update")

          if @node.update(node_params)
            render_success(node: serialize_node(@node))
          else
            render_validation_error(@node)
          end
        end

        def destroy
          require_permission("system.nodes.delete")

          if @node.destroy
            render_success(message: "Node deleted successfully")
          else
            render_error("Failed to delete node", status: :unprocessable_entity)
          end
        end

        # POST /api/v1/system/nodes/:id/apply_template
        # Materializes NodeModuleAssignment rows for this node from the
        # closure of its NodeTemplate. Idempotent — existing assignments
        # are preserved unchanged. Body params:
        #   dry_run     — preview without persisting (default false)
        #   purge_stale — remove template-derived assignments no longer
        #                 in the closure (default false; hand-authored
        #                 assignments with NULL source_template_module_id
        #                 are never purged)
        def apply_template
          require_permission("system.modules.update")

          dry_run     = ActiveModel::Type::Boolean.new.cast(params[:dry_run])
          purge_stale = ActiveModel::Type::Boolean.new.cast(params[:purge_stale])

          result = ::System::TemplateApplyService.new(@node)
                     .apply!(dry_run: dry_run, purge_stale: purge_stale)

          if result.ok?
            render_success(
              dry_run: dry_run,
              created_count: result.created.size,
              skipped_count: result.skipped.size,
              purged_count:  result.purged.size,
              warnings: result.warnings,
              errors: result.errors,
              created: result.created.map { |a| { node_module_id: a.node_module.id, source_template_module_id: a.source_template_module&.id } },
              purged_module_ids: result.purged.map(&:node_module_id)
            )
          else
            render_error(result.errors.first || "apply_template failed", status: :unprocessable_entity)
          end
        end

        private

        def set_node
          @node = @account.system_nodes.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node")
        end

        def node_params
          params.require(:node).permit(
            :name, :description, :enabled, :node_template_id, :worker_id,
            :public_address, :allocate_public_ip, :ssh_key, :ssh_host_key,
            config: {}
          )
        end

        def apply_filters(scope)
          scope = scope.enabled if params[:enabled] == "true"
          scope = scope.disabled if params[:enabled] == "false"
          scope = scope.where(node_template_id: params[:template_id]) if params[:template_id].present?
          scope.ordered
        end

        def serialize_node(node)
          ::System::NodeSerializer.new(node).as_json
        end

        def serialize_collection(nodes)
          nodes.map { |n| serialize_node(n) }
        end
      end
    end
  end
end
