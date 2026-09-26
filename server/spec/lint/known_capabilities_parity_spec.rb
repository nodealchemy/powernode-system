# frozen_string_literal: true

require "rails_helper"

# IMP-caef5c00d63f — the server's KNOWN_CAPABILITIES must be exactly the
# agent's KnownCapabilities map. The agent refuses a module naming a
# capability outside its map, and refuses the WHOLE module, so a name the
# server accepts but the agent does not is a fleet outage, and a name the
# agent knows but the server rejects is a false refusal. Parsed from the Go
# source rather than restated, so the two cannot drift silently.
RSpec.describe "KNOWN_CAPABILITIES parity with the agent" do
  go_source = File.expand_path("../../../agent/internal/security/capabilities.go", __dir__)

  it "matches agent/internal/security/capabilities.go KnownCapabilities exactly" do
    source = File.read(go_source)
    map_body = source[/var KnownCapabilities = map\[string\]struct\{\}\{(.*?)^\}/m, 1]
    expect(map_body).not_to be_nil, "KnownCapabilities map not found in #{go_source}"

    agent_caps = map_body.scan(/"(CAP_[A-Z_]+)"\s*:/).flatten
    expect(agent_caps.size).to be > 30

    expect(System::ModuleConfigValidator::KNOWN_CAPABILITIES.sort).to eq(agent_caps.sort)
  end
end
