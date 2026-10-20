# frozen_string_literal: true

module System
  # Serializer for System::BootstrapToken. CRITICAL: never returns the token,
  # its digest or the sealed copy. The plaintext of an operator key is returned
  # EXCLUSIVELY by BootstrapTokensController#create (once) and, later, by the
  # approval-gated MCP reveal verb. Fields are an allowlist, not a denylist.
  class BootstrapTokenSerializer
    def initialize(token)
      @token = token
    end

    def as_json(*)
      {
        id:               @token.id,
        purpose:          @token.purpose,
        node_instance_id: @token.node_instance_id,
        expires_at:       @token.expires_at,
        consumed_at:      @token.consumed_at,
        consumed_from_ip: @token.consumed_from_ip,
        revoked_at:       @token.revoked_at,
        created_by:       created_by,
        created_at:       @token.created_at
      }
    end

    private

    def created_by
      user = @token.created_by
      user && { id: user.id, name: user.name }
    end
  end
end
