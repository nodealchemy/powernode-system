# frozen_string_literal: true

# Extension copy of core's shared context (ext specs keep their own support).
# Restore, never reset!: Mcp::Principal.reset! nils the resolvers the system
# extension wires once at boot, which silently turns every later instance-principal
# example in the process into a refusal (order-dependent failures). Specs that set
# the resolvers include this so each example puts back what it found.
RSpec.shared_context "restores Mcp::Principal resolvers (system)" do
  around do |example|
    orig_instance = ::Mcp::Principal.instance_resolver
    orig_grant = ::Mcp::Principal.tool_grant_resolver
    example.run
  ensure
    ::Mcp::Principal.instance_resolver = orig_instance
    ::Mcp::Principal.tool_grant_resolver = orig_grant
  end
end
