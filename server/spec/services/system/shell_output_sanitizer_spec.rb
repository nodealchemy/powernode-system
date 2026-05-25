# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::ShellOutputSanitizer do
  describe ".redact" do
    it "returns nil for nil input" do
      expect(described_class.redact(nil)).to be_nil
    end

    it "returns empty string unchanged" do
      expect(described_class.redact("")).to eq("")
    end

    it "passes through plain text that contains no secrets" do
      text = "Hello world, exit code 0, 42 files synced."
      expect(described_class.redact(text)).to eq(text)
    end

    context "AWS credentials" do
      it "redacts an access key ID" do
        out = described_class.redact("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE rest")
        expect(out).not_to include("AKIAIOSFODNN7EXAMPLE")
        expect(out).to include("[REDACTED]")
      end

      it "redacts session tokens (ASIA prefix)" do
        out = described_class.redact("ASIA1234567890123456")
        expect(out).to eq("[REDACTED]")
      end

      it "redacts an aws_secret_access_key value while keeping the prefix locatable" do
        out = described_class.redact("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        expect(out).to include("aws_secret_access_key")
        expect(out).to include("[REDACTED]")
        expect(out).not_to include("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
      end
    end

    context "generic key=value secrets" do
      it "redacts password=" do
        out = described_class.redact("PGPASSWORD=hunter2-secret-pw psql -h db")
        expect(out).not_to include("hunter2-secret-pw")
      end

      it "redacts token= with colon separator" do
        out = described_class.redact("token: abcdef0123456789xyz")
        expect(out).not_to include("abcdef0123456789xyz")
      end

      it "leaves short non-secret values alone (<8 chars)" do
        # Generic password=… rule requires >=8 chars to avoid false positives
        # on `--name=foo` style flags. Short values pass through.
        out = described_class.redact("password=short")
        expect(out).to eq("password=short")
      end
    end

    context "HTTP auth headers" do
      it "redacts Bearer tokens" do
        out = described_class.redact("Authorization: Bearer abcdefABCDEF1234567890_-")
        expect(out).not_to include("abcdefABCDEF1234567890_-")
        expect(out).to include("[REDACTED]")
      end

      it "redacts a JWT" do
        jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        out = described_class.redact("token = #{jwt}")
        expect(out).not_to include(jwt)
      end
    end

    context "GitHub tokens" do
      it "redacts a classic ghp_ PAT" do
        out = described_class.redact("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        expect(out).to eq("[REDACTED]")
      end

      it "redacts a fine-grained github_pat_" do
        # 82-char body per the regex
        body = "x" * 82
        out = described_class.redact("github_pat_#{body}")
        expect(out).to eq("[REDACTED]")
      end
    end

    context "OpenAI / Anthropic / Vault tokens" do
      it "redacts an sk- key" do
        out = described_class.redact("export OPENAI_API_KEY=sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        expect(out).not_to include("sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      end

      it "redacts an sk-ant- key" do
        out = described_class.redact("ANTHROPIC_API_KEY=sk-ant-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        expect(out).not_to include("sk-ant-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
      end

      it "redacts a Vault token" do
        out = described_class.redact("VAULT_TOKEN=hvs.AAAAAAAAAAAAAAAAAAAA")
        expect(out).not_to include("hvs.AAAAAAAAAAAAAAAAAAAA")
      end
    end

    it "redacts an SSH private key block (multiline)" do
      key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAAB...\nrandomstuff\n-----END OPENSSH PRIVATE KEY-----"
      out = described_class.redact("here it is:\n#{key}\ntail")
      expect(out).to include("here it is:")
      expect(out).to include("tail")
      expect(out).to include("[REDACTED]")
      expect(out).not_to include("b3BlbnNzaC1rZXktdjEAAAAAB")
    end

    it "applies multiple patterns to the same string" do
      text = "ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA and AKIAIOSFODNN7EXAMPLE"
      out = described_class.redact(text)
      expect(out).not_to include("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
      expect(out).not_to include("AKIAIOSFODNN7EXAMPLE")
    end

    it "does not mutate its input" do
      text = "PGPASSWORD=secrethere".freeze
      described_class.redact(text)
      expect(text).to eq("PGPASSWORD=secrethere")
    end

    it "truncates very large outputs with a clipped-bytes marker" do
      huge = "x" * (described_class::MAX_LOG_BYTES + 500)
      out = described_class.redact(huge)
      expect(out.bytesize).to be > described_class::MAX_LOG_BYTES
      expect(out).to match(/\[truncated 500 bytes\]\z/)
    end
  end

  describe ".redact_payload" do
    it "recurses through hashes + arrays" do
      payload = {
        command: "echo done",
        stdout: "AKIAIOSFODNN7EXAMPLE happened",
        nested: [
          "PGPASSWORD=secretpw",
          { token: "Bearer abcdefABCDEF1234567890" }
        ],
        exit_code: 0
      }
      out = described_class.redact_payload(payload)
      expect(out[:command]).to eq("echo done")
      expect(out[:exit_code]).to eq(0)
      expect(out[:stdout]).not_to include("AKIAIOSFODNN7EXAMPLE")
      expect(out[:nested][0]).not_to include("secretpw")
      expect(out[:nested][1][:token]).not_to include("abcdefABCDEF1234567890")
    end

    it "passes through non-string / non-container leaves untouched" do
      expect(described_class.redact_payload(42)).to eq(42)
      expect(described_class.redact_payload(:sym)).to eq(:sym)
      expect(described_class.redact_payload(nil)).to be_nil
      expect(described_class.redact_payload(true)).to be true
    end
  end
end
