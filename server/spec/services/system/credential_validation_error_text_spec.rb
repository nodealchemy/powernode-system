# frozen_string_literal: true

require "rails_helper"

# The catch-all rescue in System::CredentialValidationService#test used to
# return the caught exception's own #message, which the BYOC onboarding UI
# shows verbatim. A driver's message can name the upstream host and port, an
# SDK's can echo request detail. The rescue now goes through the service's
# safe_error_text: an authored category for each failure an operator can act
# on (unreachable, unauthorized, timed out, malformed response), the raw text
# kept server-side only.
RSpec.describe System::CredentialValidationService, "caller-facing error text" do
  let(:provider) { instance_double("System::Provider", provider_type: "aws") }
  let(:raw_detail) { "probe to vault.internal.example:8200 failed for AKIAEXAMPLEKEY" }

  def probe_raising(error)
    instance = double("adapter instance")
    allow(instance).to receive(:authenticate?).and_raise(error)
    adapter = double("adapter class")
    allow(adapter).to receive(:with_credentials).and_return(instance)
    allow(System::Providers::Registry).to receive(:adapter_for).and_return(adapter)
    allow(System::Providers::Registry).to receive(:sdk_refusal).and_return(nil)
    described_class.test(provider: provider, credentials: { "access_key_id" => "AKIAEXAMPLEKEY" })
  end

  {
    "timed out" => [ -> { Net::OpenTimeout.new("execution expired") }, /timed out/i ],
    "timed out (Faraday)" => [ -> { Faraday::TimeoutError.new("timeout") }, /timed out/i ],
    "unreachable (connection refused)" => [ -> { Errno::ECONNREFUSED.new("connect(2) for vault.internal.example:8200") }, /unreachable/i ],
    "unreachable (DNS)" => [ -> { SocketError.new("getaddrinfo: Name or service not known") }, /unreachable/i ],
    "unreachable (Faraday)" => [ -> { Faraday::ConnectionFailed.new("Failed to open TCP connection") }, /unreachable/i ],
    "unauthorized" => [ -> { System::Providers::BaseProvider::AuthenticationError.new("bad token") }, /rejected the credentials/i ],
    "unauthorized (HTTP 401)" => [ -> { Faraday::UnauthorizedError.new("the server responded with status 401") }, /rejected the credentials/i ],
    "malformed response" => [ -> { JSON::ParserError.new("unexpected token at '<html>'") }, /could not parse/i ]
  }.each do |label, (build, category)|
    it "answers #{label} with its authored category and none of the raw text" do
      ok, message = probe_raising(build.call)

      expect(ok).to be false
      expect(message).to match(category)
      expect(message).not_to include("vault.internal.example")
      expect(message).not_to include("8200")
      expect(message).not_to include("execution expired")
      expect(message).not_to include("unexpected token")
    end
  end

  it "answers an uncategorised failure with authored guidance, never the exception's message" do
    ok, message = probe_raising(RuntimeError.new(raw_detail))

    expect(ok).to be false
    expect(message).not_to include(raw_detail)
    expect(message).not_to include("AKIAEXAMPLEKEY")
    expect(message).to match(/server log/i)
  end

  it "classifies a subclass through its ancestor, so a future SDK error still lands in a category" do
    stub_const("SpecProbeReadTimeout", Class.new(Net::ReadTimeout))

    _ok, message = probe_raising(SpecProbeReadTimeout.new("read timeout"))

    expect(message).to match(/timed out/i)
  end

  it "keeps the withheld text server-side, redacted" do
    allow(Rails.logger).to receive(:error)

    probe_raising(RuntimeError.new(raw_detail))

    expect(Rails.logger).to have_received(:error).with(/CredentialValidationService.*RuntimeError/)
  end
end
