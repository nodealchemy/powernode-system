# frozen_string_literal: true

module System
  # ONE home for the bound on node-supplied identifier strings.
  #
  # Every string on this list arrives from a node — a compromised or simply
  # buggy agent can make it as large as it likes — and is then read back on
  # fleet reads, including into an LLM context via the MCP serializers. The
  # bound is what stops one field from one node filling a context window.
  #
  # WHY A SHARED CONSTANT RATHER THAN A LITERAL PER WRITE SURFACE. The cap is
  # applied at two genuinely different surfaces: the state writers bound
  # strings inside the `config` jsonb sub-documents they own, written with raw
  # `update_all` SQL, while NodeInstance bounds real model columns assigned
  # through the ordinary ActiveRecord attribute path. Those need different
  # HELPERS — but they do not need different NUMBERS, and a second literal kept
  # in step by a comment is the drift shape this platform keeps rediscovering.
  # The helpers stay separate; the bound is stated once, here.
  #
  # Deliberately NOT part of System::ConfigDocument: that concern is the shared
  # jsonb merge seam, not a place for scalar bounds.
  module IdentifierCaps
    MAX_IDENTIFIER_CHARS = 128
  end
end
