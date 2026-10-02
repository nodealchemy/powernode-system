# frozen_string_literal: true

require "rails_helper"

# IMP-fdc3b6a53d77 — where Acme::LegoClient finds powernode-acme on a BUILT hub. The dev-tree
# agent/dist path is not shipped (the extension-system module masks it), so the binary that the
# hub's own build ships — /usr/sbin/powernode-acme from powernode-system-base — has to resolve.
RSpec.describe Acme::LegoClient, "binary resolution" do
  let(:client) { described_class.new }
  let(:shipped) { "/usr/sbin/powernode-acme" }

  around do |example|
    saved = ENV.delete("POWERNODE_ACME_BIN")
    example.run
  ensure
    ENV["POWERNODE_ACME_BIN"] = saved if saved
  end

  def executable_only(*paths)
    allow(::File).to receive(:executable?).and_call_original
    allow(::File).to receive(:executable?) { |p| paths.include?(p.to_s) }
    allow(::File).to receive(:file?).and_call_original
    allow(::File).to receive(:file?) { |p| paths.include?(p.to_s) }
  end

  it "resolves the binary the hub build ships at /usr/sbin/powernode-acme" do
    executable_only(shipped)

    expect(client.send(:resolve_binary_path)).to eq(shipped)
  end

  it "prefers an explicit POWERNODE_ACME_BIN over the shipped path" do
    ENV["POWERNODE_ACME_BIN"] = "/opt/custom/acme"
    executable_only("/opt/custom/acme", shipped)

    expect(client.send(:resolve_binary_path)).to eq("/opt/custom/acme")
  end

  it "prefers the shipped path over a stale dev-tree dist build" do
    dist = ::Rails.root.join("..", "extensions", "system", "agent", "dist").to_s
    executable_only(shipped, "#{dist}/powernode-acme-linux-amd64", "#{dist}/powernode-acme-linux-arm64")

    expect(client.send(:resolve_binary_path)).to eq(shipped)
  end

  it "falls back to the dev-tree dist build when nothing is shipped" do
    arch = `uname -m`.strip == "x86_64" ? "amd64" : "arm64"
    dist = ::Rails.root.join("..", "extensions", "system", "agent", "dist", "powernode-acme-linux-#{arch}").to_s
    executable_only(dist)

    expect(client.send(:resolve_binary_path)).to eq(dist)
  end

  it "does not take a directory that merely has the x bit" do
    allow(::File).to receive(:executable?).and_return(true)
    allow(::File).to receive(:file?).and_return(false)

    expect { client.send(:resolve_binary_path) }.to raise_error(Acme::LegoClient::IntegrationError)
  end

  it "fails loud when nothing resolves, naming where it looked and how the build ships it" do
    executable_only

    expect { client.send(:resolve_binary_path) }
      .to raise_error(Acme::LegoClient::IntegrationError, %r{/usr/sbin/powernode-acme.*powernode-system-base}m)
  end
end
