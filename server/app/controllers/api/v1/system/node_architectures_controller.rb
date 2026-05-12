# frozen_string_literal: true

module Api
  module V1
    module System
      class NodeArchitecturesController < BaseController
        # NodeArchitecture went platform-wide (i-would-like-to-zesty-glade.md
        # Tier 1). The catalog is shared across every account and can only
        # be mutated by users with system.architectures.manage; canonical
        # rows are immutable via the API (migration is the only path).
        before_action :set_architecture, only: [ :show, :update, :destroy ]

        def index
          require_permission("system.architectures.read")
          architectures = ::System::NodeArchitecture.all
          architectures = apply_filters(architectures)
          architectures = paginate(architectures)
          render_success(node_architectures: serialize_collection(architectures), meta: pagination_meta)
        end

        def show
          require_permission("system.architectures.read")
          render_success(node_architecture: serialize_architecture(@architecture))
        end

        def create
          require_permission("system.architectures.manage")
          architecture = ::System::NodeArchitecture.new(architecture_params)
          architecture.is_canonical = false # operators can't fabricate canonicals via the API

          if architecture.save
            render_success(node_architecture: serialize_architecture(architecture), status: :created)
          else
            render_validation_error(architecture)
          end
        end

        def update
          require_permission("system.architectures.manage")
          return render_canonical_protected if @architecture.protected_canonical?

          if @architecture.update(architecture_params.except(:is_canonical))
            render_success(node_architecture: serialize_architecture(@architecture))
          else
            render_validation_error(@architecture)
          end
        end

        def destroy
          require_permission("system.architectures.manage")
          return render_canonical_protected if @architecture.protected_canonical?

          if @architecture.destroy
            render_success(message: "Architecture deleted successfully")
          else
            render_error("Failed to delete architecture", status: :unprocessable_entity)
          end
        end

        private

        def set_architecture
          @architecture = ::System::NodeArchitecture.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render_not_found("Node Architecture")
        end

        def render_canonical_protected
          render_error(
            "Canonical architectures are immutable via the API. Evolve them via a database migration.",
            status: :forbidden
          )
        end

        def architecture_params
          params.require(:node_architecture).permit(
            :name, :description, :apt_name, :rpm_name, :display_name, :family,
            :enabled, :public, :kernel_options,
            :kernel_file_object_id, :ramdisk_file_object_id, :image_file_object_id,
            aliases: []
          )
        end

        def apply_filters(scope)
          scope = scope.enabled        if params[:enabled] == "true"
          scope = scope.disabled       if params[:enabled] == "false"
          scope = scope.public_access  if params[:public] == "true"
          scope = scope.canonical      if params[:is_canonical] == "true"
          scope = scope.custom         if params[:is_canonical] == "false"
          scope = scope.by_family(params[:family]) if params[:family].present?
          scope.ordered
        end

        def serialize_architecture(architecture)
          ::System::NodeArchitectureSerializer.new(architecture).as_json
        end

        def serialize_collection(architectures)
          architectures.map { |a| serialize_architecture(a) }
        end
      end
    end
  end
end
