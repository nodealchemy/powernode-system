# frozen_string_literal: true

module System
  # The `environment` query parameter on a fleet LIST surface: narrow the
  # answer to one plane of the fleet, named by slug or Ai::Environment id.
  #
  # Unknown is FAIL CLOSED (404), and that is the reason this is a concern
  # rather than four inline `where`s. The alternative — ignore a filter that
  # cannot be resolved — answers "what is running in prod" with rows from every
  # plane, which is the most dangerous possible misreading of the question. It
  # is the same refusal Ai::Tools::BaseTool#environment_filter raises on the
  # MCP half and the same one System::EnvironmentResolver makes when an ACTION
  # names a plane the account does not have.
  #
  # Wired as a `before_action`, never called from an action body: a render from
  # a body does not halt the action, so an unresolvable plane would 404 and
  # then run the query anyway. Declare it AFTER whatever sets the account.
  module EnvironmentFilterable
    extend ActiveSupport::Concern

    private

    def set_environment_filter
      named = params[:environment].to_s
      return if named.blank?

      @environment_filter = ::Ai::Environment.find_for_account(current_account.id, named)
      return if @environment_filter

      render_error("environment '#{named}' not found in this account", 404)
    end

    # `in_environment` is declared by every plane-bearing fleet model, so a
    # model that carries no environment_id fails loudly here instead of
    # quietly returning the whole fleet.
    def filter_by_environment(scope)
      @environment_filter ? scope.in_environment(@environment_filter) : scope
    end
  end
end
