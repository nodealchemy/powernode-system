# frozen_string_literal: true

require "rails_helper"
require "base64"

RSpec.describe System::StoredOutputRedactor do
  # IMP-33ab99763220 — the node agent's ci.module_build result carries a
  # log_tail of the REAL shape `stdout: <tail>\nstderr: <tail>`, each tail a
  # byte-bounded window cut at an offset. A key printed by a build step whose
  # BEGIN header fell before the cut arrives here as a HEADERLESS PEM body
  # immediately after `stdout: ` or after `\nstderr: `. ShellOutputSanitizer's
  # PEM patterns key on the header; this redactor's PEM_BODY_LEAD strip is
  # anchored at the start of ITS OWN tail window. These examples pin, per
  # shape, whether such a body is served over the MCP read verbs. A shape that
  # leaks is held `pending` (the agent now strips it at the source, and the
  # example flips to a failure the day a server-side strip lands so the
  # pending can be retired).
  #
  # Synthetic key material only: seeded random bytes, base64 in 64-column
  # lines, as a PEM body is shaped. Never a real key.
  let(:body_lines) do
    bytes = Random.new(33_099).bytes(480)
    Base64.strict_encode64(bytes).scan(/.{1,64}/)
  end
  let(:body) { body_lines.join("\n") }
  let(:probe) { body_lines[2] }
  let(:end_line) { "-----END RSA PRIVATE KEY-----" }

  # The production limits of the two read surfaces that serve a task result
  # (Ai::Tools::SystemFleetTool get_task events / inspect_task result).
  let(:events_limits) { { limit: 20, string_limit: 16_384, max_chars: 131_072, max_nodes: 5_000 } }
  let(:inspect_limits) { { limit: 1, string_limit: 72_000, max_chars: 200_000, max_nodes: 2_000 } }

  # Measured 2026-09-30 on develop: every headerless shape below is served
  # verbatim on both surfaces. The agent strips the cut body at the source
  # (module_build.go tailBytes); the server still cannot see a body whose
  # header it never received.
  let(:server_gap) { "IMP-33ab99763220: headerless PEM body after an agent window cut is not stripped server-side" }

  def served(text, limits)
    described_class.events([ { "type" => "result", "result" => { "log_tail" => text } } ], **limits).to_json
  end

  describe "a headerless PEM body in an agent-shaped log_tail" do
    it "proves the probe line is detectable: a HEADED key in the same shape is redacted" do
      text = "stdout: -----BEGIN RSA PRIVATE KEY-----\n#{body}\n#{end_line}\n{\"ok\":true}\nstderr: build ok"
      out = served(text, events_limits)
      expect(out).not_to include(probe)
      expect(out).to include("[REDACTED]")
    end

    context "immediately after `stdout: ` with a trailing END marker" do
      let(:text) { "stdout: #{body}\n#{end_line}\n{\"ok\":true}\nstderr: npm notice done" }

      it "is withheld on the get_task events surface" do
        pending server_gap
        expect(served(text, events_limits)).not_to include(probe)
      end

      it "is withheld on the inspect_task result surface" do
        pending server_gap
        expect(served(text, inspect_limits)).not_to include(probe)
      end

      it "is withheld by .bounded with the log_tail lead" do
        pending server_gap
        out = described_class.bounded(text, 16_384, from: :tail, lead: "log_tail: ", inclusive: true)
        expect(out).not_to include(probe)
      end
    end

    context "immediately after `stdout: ` with no END marker, then prose" do
      let(:text) { "stdout: #{body}\n{\"ok\":true}\nstderr: npm notice done" }

      it "is withheld on the get_task events surface" do
        pending server_gap
        expect(served(text, events_limits)).not_to include(probe)
      end

      it "is withheld on the inspect_task result surface" do
        pending server_gap
        expect(served(text, inspect_limits)).not_to include(probe)
      end
    end

    context "immediately after `\\nstderr: ` with a trailing END marker" do
      let(:text) { "stdout: {\"ok\":false}\nstderr: #{body}\n#{end_line}\nerror: stage 3 failed" }

      it "is withheld on the get_task events surface" do
        pending server_gap
        expect(served(text, events_limits)).not_to include(probe)
      end

      it "is withheld on the inspect_task result surface" do
        pending server_gap
        expect(served(text, inspect_limits)).not_to include(probe)
      end
    end

    context "immediately after `\\nstderr: ` with no END marker, running to the end" do
      let(:text) { "stdout: {\"ok\":false}\nstderr: #{body}" }

      it "is withheld on the get_task events surface" do
        pending server_gap
        expect(served(text, events_limits)).not_to include(probe)
      end

      it "is withheld on the inspect_task result surface" do
        pending server_gap
        expect(served(text, inspect_limits)).not_to include(probe)
      end
    end
  end
end
