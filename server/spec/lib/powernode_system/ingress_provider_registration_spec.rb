# frozen_string_literal: true

require "rails_helper"

# Confirms the system extension's engine initializer
# ("powernode_system.register", lib/powernode_system/engine.rb) actually
# registered the ingress provider seam (docs/operations/reverse-proxy.md
# §7-8, campaign 019f3458 increment 8) at boot: both `:ingress_certs` and
# `:ingress_routers` must resolve to Acme::TraefikConfigWriter, and to the
# SAME object — Core::IngressConfigWriter.extension_writer only engages the
# seam when both facets agree.
RSpec.describe "PowernodeSystem ingress provider registration", type: :lib do
  it "registers Acme::TraefikConfigWriter as the :ingress_certs provider" do
    expect(::Powernode::ExtensionRegistry.provider(:ingress_certs)).to eq(::Acme::TraefikConfigWriter)
  end

  it "registers Acme::TraefikConfigWriter as the :ingress_routers provider" do
    expect(::Powernode::ExtensionRegistry.provider(:ingress_routers)).to eq(::Acme::TraefikConfigWriter)
  end

  it "resolves both facets to the identical object, so Core engages the full-delegation seam" do
    expect(::Core::IngressConfigWriter.extension_writer).to eq(::Acme::TraefikConfigWriter)
  end
end
