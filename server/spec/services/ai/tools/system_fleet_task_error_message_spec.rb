# frozen_string_literal: true

require "rails_helper"

# IMP-b8af3c3309fe — System::Task carries an error_message column that is
# populated on every failure transition, but serialize_task never returned it.
# A failed task was therefore observable over MCP as `status: "failed"` with no
# reason attached, and diagnosing one real ci.module_build failure required
# arming a read-only Postgres breakglass on the control plane to read a single
# actionable line the platform had already stored. The escalation carried more
# risk than the thing being diagnosed.
#
# error_message holds BUILD AND SHELL OUTPUT — command lines, env dumps, argv.
# So the fix is not "add the column to the hash": it is redact first (CLAUDE.md
# forbids transmitting key material in any form), then size-limit. The redaction
# assertions below are the load-bearing half of this spec.
#
# Two properties every redaction example asserts TOGETHER, because either alone
# is satisfiable by a broken implementation:
#   - the secret does not survive   (a raw pass-through fails this)
#   - the FAILURE REASON does survive (a redactor that eats the rest of the
#     message fails this — which is exactly what an unbounded "delete
#     everything after a PEM header" pattern does, and it defeats the whole
#     point of surfacing the field)
#
# Truncation is a size control ONLY — it must never be the thing that happens
# to cut a secret off, which is why every planted secret sits at the FRONT of
# the message, well inside the list limit.
#
# Every planted token in this file is a synthetic fixture. None is, or resembles
# in value, a credential from any real environment.
RSpec.describe Ai::Tools::SystemFleetTool, "task error_message serialization" do
  let(:account) { create(:account) }
  let(:user)    { create(:user, :super_admin, account: account) }
  let(:node)    { create(:system_node, account: account) }

  subject(:tool) { described_class.new(account: account, user: user) }

  def make_task(error_message)
    create(:system_task, :failed, account: account, operable: node,
           command: "ci.module_build", error_message: error_message)
  end

  def get_task(task)
    tool.execute(params: { action: "system_get_task", id: task.id })
  end

  def listed(task)
    result = tool.execute(params: { action: "system_list_tasks" })
    expect(result[:success]).to be(true)
    (result[:data][:tasks] || []).find { |t| t[:id] == task.id }
  end

  describe "the failure reason reaches the operator at all" do
    let(:reason) { "[stage-1.5] FATAL: no @vendor-official/linux-* platform package staged" }

    it "returns the full error_message from system_get_task" do
      task   = make_task(reason)
      result = get_task(task)

      expect(result[:success]).to be(true)
      expect(result[:data][:task][:error_message]).to eq(reason)
    end

    it "returns the error_message from system_list_tasks" do
      task = make_task(reason)

      expect(listed(task)[:error_message]).to eq(reason)
    end

    it "returns a nil error_message rather than omitting the key on a task that has none" do
      task = create(:system_task, account: account, operable: node)

      expect(get_task(task)[:data][:task]).to have_key(:error_message)
      expect(get_task(task)[:data][:task][:error_message]).to be_nil
    end
  end

  # Each shape is planted at the FRONT of the message, so nothing here can pass
  # merely because truncation clipped it off. Held in a local rather than a
  # constant: a constant declared inside an example group leaks into the suite's
  # namespace and can be clobbered by a same-named one elsewhere.
  secret_shapes = {
    "an sk- style API key" => [
      "sk-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE9999",
      "sk-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE9999"
    ],
    "an sk-ant- style API key" => [
      "sk-ant-api00-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE9999",
      "FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE9999"
    ],
    "a bearer token in an Authorization header" => [
      "curl -H 'Authorization: Bearer FAKEfaketoken0123456789abcdefGHIJ' https://registry.invalid",
      "FAKEfaketoken0123456789abcdefGHIJ"
    ],
    "a token= query fragment" => [
      "git clone https://git.invalid/repo.git?token=FAKEtoken1234567890 failed",
      "FAKEtoken1234567890"
    ],
    "a password= assignment" => [
      "psql: connection refused (password=FAKEpassword12345)",
      "FAKEpassword12345"
    ],
    # The shapes below were added after an independent review demonstrated each
    # of them surviving the first cut of this change. Every one is a command
    # this platform's own module builds actually run.
    "a credential in a git remote URL" => [
      "fatal: unable to access 'https://pnbot:FAKEurltoken12345@git.invalid/powernode/core.git/': 403",
      "FAKEurltoken12345"
    ],
    "a JSON-quoted password key" => [
      %({"error":"auth failed","password":"FAKEjsonsecret12345"}),
      "FAKEjsonsecret12345"
    ],
    "a docker/registry auths blob" => [
      %({"auths":{"registry.invalid":{"auth":"RkFLRWRvY2tlcmF1dGhGQUtF"}}}),
      "RkFLRWRvY2tlcmF1dGhGQUtF"
    ],
    "a credential passed as a space-separated CLI flag" => [
      "+ oras login registry.invalid -u ci-bot --password FAKEflagsecret12345",
      "FAKEflagsecret12345"
    ],
    "the platform's own SECRET_KEY_BASE in an env dump" => [
      "SECRET_KEY_BASE=FAKEenvsecretbase1234567890abcdef",
      "FAKEenvsecretbase1234567890abcdef"
    ],
    "a .netrc credential line" => [
      "machine git.invalid login pnbot password FAKEnetrcsecret12345",
      "FAKEnetrcsecret12345"
    ],
    "an env-style API key dump" => [
      "POWERNODE_API_KEY=FAKEenvkey1234567890",
      "FAKEenvkey1234567890"
    ],
    "a JWT" => [
      "auth rejected: eyJhbGciOiJIUzI1NiJ9.eyJmYWtlIjoidmFsdWUifQ.FAKEsignature0123456789",
      "eyJhbGciOiJIUzI1NiJ9.eyJmYWtlIjoidmFsdWUifQ.FAKEsignature0123456789"
    ],
    "a complete PEM private-key block" => [
      "-----BEGIN OPENSSH PRIVATE KEY-----\nRkFLRWtleW1hdGVyaWFsRkFLRQ==\n-----END OPENSSH PRIVATE KEY-----",
      "RkFLRWtleW1hdGVyaWFsRkFLRQ=="
    ],
    # cosign's real header. The footer-anchored block pattern never matched it,
    # so a complete cosign key was passing through in one piece.
    "a complete cosign ENCRYPTED SIGSTORE key block" => [
      "-----BEGIN ENCRYPTED SIGSTORE PRIVATE KEY-----\nRkFLRXNpZ3N0b3Jla2V5bWF0ZXJpYWxGQUtFRkFLRUZBS0U=\n-----END ENCRYPTED SIGSTORE PRIVATE KEY-----",
      "RkFLRXNpZ3N0b3Jla2V5bWF0ZXJpYWxGQUtFRkFLRUZBS0U="
    ],
    # The clipped-key case: output cut off mid-key upstream has a BEGIN header
    # and no END footer, and the body bytes are still key material.
    "a PEM private-key block with no closing footer" => [
      "-----BEGIN RSA PRIVATE KEY-----\nRkFLRWNsaXBwZWRrZXltYXRlcmlhbEZBS0VGQUtFRkFLRUZB\n",
      "RkFLRWNsaXBwZWRrZXltYXRlcmlhbEZBS0VGQUtFRkFLRUZB"
    ]
  }.freeze

  describe "redaction (adversarial — every shape must die on BOTH surfaces)" do
    secret_shapes.each do |shape, (planted, leaked_fragment)|
      it "kills #{shape} on system_get_task without eating the failure reason" do
        task = make_task("#{planted}\nbuild aborted at stage 3")

        body = get_task(task)[:data][:task][:error_message].to_s

        expect(body).not_to include(leaked_fragment)
        expect(body).to include("REDACTED")
        expect(body).to include("build aborted at stage 3")
      end

      it "kills #{shape} on system_list_tasks without eating the failure reason" do
        task = make_task("#{planted}\nbuild aborted at stage 3")

        body = listed(task)[:error_message].to_s

        expect(body).not_to include(leaked_fragment)
        expect(body).to include("REDACTED")
        expect(body).to include("build aborted at stage 3")
      end
    end

    # The redactor must not be usable as an excuse to stop reading the field:
    # a tool that merely NAMES a key file carries no key material, and eating
    # the line after it would delete the actual reason.
    it "leaves a bare mention of a PEM header with no key body otherwise intact" do
      task = make_task(
        %(ssh-keygen: line 1: unsupported PEM block "-----BEGIN OPENSSH PRIVATE KEY-----"\n) +
        "FATAL: stage-3 build failed: no space left on device"
      )

      expect(get_task(task)[:data][:task][:error_message])
        .to include("FATAL: stage-3 build failed: no space left on device")
    end

    it "leaves an ordinary auth-failure diagnostic readable" do
      reason = %(psql: FATAL: password authentication failed for user "powernode")
      task   = make_task(reason)

      expect(get_task(task)[:data][:task][:error_message]).to eq(reason)
    end
  end

  describe "size control" do
    # Deliberately larger than ShellOutputSanitizer::MAX_LOG_BYTES (4096): the
    # single-task read must NOT inherit the sanitizer's log cap, which is the
    # entire reason this path calls .redact_text rather than .redact. Swap one
    # for the other and this example goes red.
    let(:long_reason) { "stage-3 failure: #{'diagnostic output ' * 300}" }

    it "truncates in system_list_tasks with a marker" do
      task = make_task(long_reason)

      body = listed(task)[:error_message]

      expect(body.length).to be < long_reason.length
      expect(body).to include("truncated")
      expect(long_reason).to start_with(body.sub("...[truncated]", ""))
    end

    it "does not apply the sanitizer's 4KB log cap to system_get_task" do
      expect(long_reason.bytesize).to be > ::System::ShellOutputSanitizer::MAX_LOG_BYTES

      body = get_task(make_task(long_reason))[:data][:task][:error_message]

      expect(body).to eq(long_reason)
      expect(body).not_to include("truncated")
    end

    it "caps the single-task read so an unbounded agent-written blob cannot be relayed whole" do
      huge = "boom " * 20_000
      body = get_task(make_task(huge))[:data][:task][:error_message]

      expect(body.length).to be <= described_class::GET_ERROR_MESSAGE_LIMIT + 20
      expect(body).to include("truncated")
    end

    # Ordering proof. The secret sits past the LIST limit but inside the text
    # system_get_task returns, so only a redact-BEFORE-truncate implementation
    # keeps it out of both: truncating first would leave get_task returning it
    # verbatim.
    it "redacts before truncating, so a secret past the list limit is gone in both places" do
      tail_secret = "sk-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE7777"
      task = make_task("stage-3 failure: #{'diagnostic output ' * 40}\n#{tail_secret}")

      expect(get_task(task)[:data][:task][:error_message]).not_to include(tail_secret)
      expect(listed(task)[:error_message]).not_to include(tail_secret)
    end
  end
end
