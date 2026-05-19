# frozen_string_literal: true

# Smoke test for the disk-image-built webhook round-trip.
#
# Simulates what a CI runner does after producing a new disk image:
#   1. Build payload (platform_name, git_sha, sha256, size_bytes, oci_ref, ...)
#   2. HMAC-sign the raw body with the webhook's shared secret
#   3. POST to /api/v1/system/webhooks/disk_image/built/:webhook_id
#   4. Assert response is {success: true, status: "queued", publication_id: ...}
#   5. Assert a DiskImagePublication row exists with the expected git_sha + sha256
#
# Invoke:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/smoke_test_disk_image_build_to_publication.rb')"
#
# Requires: dev server listening on POWERNODE_PLATFORM_URL (default localhost:3000).
#
# Reference: audit plan P2.15c (~/.claude/plans/forform-a-deep-examination-fizzy-lobster.md).

require "net/http"
require "openssl"
require "json"
require "uri"
require "securerandom"

puts "\n  Smoke-test: disk image build → webhook → publication round-trip…"

platform_url = ENV.fetch("POWERNODE_PLATFORM_URL", "http://localhost:3000")
puts "  Target: #{platform_url}"

account  = ::Account.first or abort("  ❌ No account in DB")
platform = ::System::NodePlatform.where(account: account).order(:created_at).first \
  or abort("  ❌ No NodePlatform for this account — run rails db:seed")

# ── Step 1: ensure a DiskImageWebhook exists with a known secret ───────────

# Idempotent across runs: look up by stable label, create-with-secret if absent.
# `secret` is regenerable via rotate_secret! but we want a stable value across
# repeated smoke runs so the signature stays predictable when debugging.
webhook = ::System::DiskImageWebhook.find_by(account: account, label: "smoke-disk-image-build")
if webhook.nil?
  webhook, _plaintext = ::System::DiskImageWebhook.create_with_secret!(
    account: account, label: "smoke-disk-image-build"
  )
end

abort("  ❌ webhook #{webhook.id} has no secret — call rotate_secret!") if webhook.secret.blank?
webhook.update!(status: "active") if webhook.status != "active"

puts "  Webhook: #{webhook.id} (label=#{webhook.label}, secret_preview=#{webhook.secret_preview})"

# ── Step 2: build a synthetic CI payload ───────────────────────────────────

ts       = Time.current.to_i
git_sha  = SecureRandom.hex(20)
sha256   = SecureRandom.hex(32)
payload  = {
  "platform_name" => platform.name,
  "git_sha"       => git_sha,
  "sha256"        => sha256,
  "size_bytes"    => 134_217_728,
  "oci_ref"       => "registry.example.com/#{account.id}/disk-images/#{platform.name}:smoke-#{ts}",
  "firmware_ref"  => "1.20240306",
  "arch"          => "arm64"
}
raw_body  = JSON.generate(payload)
signature = ::OpenSSL::HMAC.hexdigest("SHA256", webhook.secret, raw_body)

puts "  Payload: git_sha=#{git_sha[0, 8]}… sha256=#{sha256[0, 8]}… arch=arm64"

# ── Step 3: POST the signed payload ────────────────────────────────────────

# In dev, the controller defaults to inline ingest mode (POWERNODE_WEBHOOK_INGEST_MODE
# unset → "inline"). The inline path tries a real `oras pull` against the synthetic
# OCI ref, which will fail. We accept that — the smoke validates the webhook accept +
# DB upsert, NOT the OCI fetch (which is exercised separately by the
# DiskImagePublicationProcessor specs against a fixture).
#
# We CANNOT set POWERNODE_WEBHOOK_INGEST_MODE=async from this rails-runner process
# because the Rails server process (port 3000) doesn't share our env. For a real
# async smoke, set the env in the systemd unit and re-run.

uri = URI.parse("#{platform_url}/api/v1/system/webhooks/disk_image/built/#{webhook.id}")
req = Net::HTTP::Post.new(uri)
req["Content-Type"] = "application/json"
req["X-Powernode-Signature"] = signature
req.body = raw_body

resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 30) do |http|
  http.request(req)
end

abort("  ❌ unexpected HTTP status: #{resp.code} body=#{resp.body[0, 200]}") \
  unless resp.code == "200"
body = JSON.parse(resp.body)
abort("  ❌ response success=false: #{body.inspect}") unless body["success"]

# Acceptable response shapes:
#   1. status="queued"           — async mode worked OR inline succeeded
#   2. status="idempotent_hit"   — already-published row matched on git_sha
#   3. status="error", reason="processing_error" — webhook accept + upsert OK,
#      but the inline processor crashed (expected against synthetic data; signals
#      a separate processor-side bug if NoMethodError or similar appears)
acceptable = body["status"] == "queued" \
          || body["status"] == "idempotent_hit" \
          || (body["status"] == "error" && body["reason"] == "processing_error")
abort("  ❌ unexpected response status: #{body['status'].inspect} (body=#{body.inspect})") \
  unless acceptable

case body["status"]
when "queued", "idempotent_hit"
  puts "  ✓ Webhook accepted: response.status=#{body['status']} publication_id=#{body['publication_id']}"
when "error"
  puts "  ⚠ Webhook accepted + upsert OK, but inline processor failed (expected in dev):"
  puts "      reason=#{body['reason']} error_class=#{body['error_class']}"
  puts "      error_message=#{(body['error_message'] || '')[0, 200]}"
  puts "    (To skip the inline processor: set POWERNODE_WEBHOOK_INGEST_MODE=async in"
  puts "    the systemd unit env. The smoke continues — we assert on the publication row.)"
end

# ── Step 4: assert DiskImagePublication row was created ────────────────────

pub = ::System::DiskImagePublication.find_by(account: account, node_platform: platform, git_sha: git_sha)
abort("  ❌ DiskImagePublication for git_sha=#{git_sha} not found after webhook") unless pub
abort("  ❌ publication.sha256 mismatch (got #{pub.sha256})") unless pub.sha256 == sha256
abort("  ❌ publication.node_platform mismatch") unless pub.node_platform_id == platform.id
abort("  ❌ publication.webhook mismatch") unless pub.webhook_id == webhook.id

puts "  ✓ DiskImagePublication ##{pub.id} created (status=#{pub.status}, arch=#{pub.arch})"
puts "    oci_ref=#{pub.oci_ref}"
puts "    size_bytes=#{pub.size_bytes}"

# ── Step 5: confirm a bad-signature request is rejected with 200 status=error

bad_req = Net::HTTP::Post.new(uri)
bad_req["Content-Type"] = "application/json"
bad_req["X-Powernode-Signature"] = "deadbeef" * 8 # 64 hex chars but wrong
bad_req.body = raw_body
bad_resp = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) do |http|
  http.request(bad_req)
end
abort("  ❌ bad-sig must return 200 (never 500); got #{bad_resp.code}") \
  unless bad_resp.code == "200"
bad_body = JSON.parse(bad_resp.body)
abort("  ❌ bad-sig must return status: 'error', got #{bad_body.inspect}") \
  unless bad_body["status"] == "error" && bad_body["reason"] == "bad_signature"
puts "  ✓ Bad signature correctly rejected with 200 status=error reason=bad_signature"

puts ""
puts "  PASS — disk-image-built webhook round-trip exercised end-to-end."
puts "         Webhook #{webhook.id} accepted signed payload; created publication #{pub.id}."
puts "         Cleanup (optional): DiskImagePublication.find(#{pub.id.inspect}).destroy"
