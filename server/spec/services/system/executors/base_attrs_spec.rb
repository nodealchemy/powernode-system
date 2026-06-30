# frozen_string_literal: true

require "rails_helper"

# Covers the shared `attrs` helper extracted onto System::Executors::Base — the
# `params[:attributes].to_h.symbolize_keys` coercion the SDWAN CRUD executors
# repeated verbatim.
RSpec.describe System::Executors::Base do
  let(:klass) do
    Class.new(described_class) do
      def perform = attrs
    end
  end

  def coerced(params)
    klass.new(params, deferred_operation: nil).send(:attrs)
  end

  it "coerces params[:attributes] to a symbol-keyed Hash" do
    expect(coerced(attributes: { "name" => "edge", "listen_port" => 51_820 }))
      .to eq(name: "edge", listen_port: 51_820)
  end

  it "is nil-safe when attributes are missing (returns {})" do
    expect(coerced({})).to eq({})
  end

  it "returns a fresh Hash each call (safe to merge without mutating params)" do
    exec = klass.new({ attributes: { "a" => 1 } }, deferred_operation: nil)
    first = exec.send(:attrs)
    first[:injected] = true
    expect(exec.send(:attrs)).to eq(a: 1) # not polluted by the previous caller
  end
end
