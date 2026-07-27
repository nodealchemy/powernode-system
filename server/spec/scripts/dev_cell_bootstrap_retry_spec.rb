# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

# Boot-race regression (observed 2026-07-27 on ops-hub-dev-cell-1784413717):
# dev-cell-bootstrap.service runs immediately after the pivot's switch-root,
# in the same second systemd-resolved is restarting, so its very first fetch
# hit "curl: (6) Could not resolve host". The unit's Restart=on-failure
# recovered it 17s later — but dev-cell-mcp-proxy.service, which Requires= it,
# had already had its start job cancelled, and systemd never re-queues a job
# cancelled by a failed dependency. The proxy stayed dead for the whole boot
# (nothing on 127.0.0.1:18443 → the cell's MCP was unreachable).
#
# The fix absorbs the transient inside the script so the UNIT never enters
# `failed` — that is the property these examples pin. It drives the REAL
# script with a stubbed `curl` whose per-attempt behavior is scripted through
# a counter file, same hermetic-sandbox shape as
# module_forge_build_head_sha_spec.rb.
RSpec.describe "dev-cell-bootstrap.sh transient-fetch retry" do
  let(:script) do
    File.expand_path(
      "../../../modules/dev-cell/rootfs/usr/local/bin/dev-cell-bootstrap.sh", __dir__
    )
  end

  # A well-formed bootstrap bundle. The values are inert test fixtures — the
  # script only checks shape (mcp.mcp_url + gitea.clone_url + private_key).
  BUNDLE = {
    "mcp"   => { "mcp_url" => "https://ops-hub.invalid/api/v1/mcp/message" },
    "gitea" => {
      "clone_url"   => "ssh://git@gitea.invalid:2222/powernode/powernode-platform.git",
      "private_key" => "-----BEGIN OPENSSH PRIVATE KEY-----\nstub\n-----END OPENSSH PRIVATE KEY-----\n",
      "known_hosts" => "[gitea.invalid]:2222 ssh-ed25519 AAAAstub\n"
    }
  }.freeze

  # Runs the script in a hermetic sandbox with a stubbed curl.
  #
  # `outcomes` scripts one entry per attempt:
  #   "dns"   → exit 6 (could not resolve host) — the observed pivot failure
  #   "200"   → writes the bundle, prints 200
  #   any other string → printed as the HTTP code, no body
  #
  # Returns [status, stdout+stderr, attempts_made, runtime_dir_contents].
  def run_bootstrap(outcomes, attempts: 6, retry_delay: 0)
    Dir.mktmpdir("dev-cell-bootstrap-test") do |root|
      stubs    = File.join(root, "stubs")
      pki      = File.join(root, "pki")
      runtime  = File.join(root, "run-dev-cell")
      counter  = File.join(root, "attempts")
      [stubs, pki, runtime].each { |d| FileUtils.mkdir_p(d) }

      # Enough of an "enrolled" identity for PKI resolution + meta.json's
      # platform_url to satisfy the script. No real key material.
      %w[node.crt node.key ca-bundle.crt].each { |f| File.write(File.join(pki, f), "stub-#{f}\n") }
      File.write(File.join(pki, "meta.json"), '{"platform_url":"https://ops-hub.invalid"}')
      File.write(counter, "0")

      write_stub(stubs, "curl", curl_stub(outcomes))
      # jq is a real dependency of the parse path; fall back to the system one.
      env = {
        "PATH"                            => "#{stubs}:/usr/local/bin:/usr/bin:/bin",
        "DEV_CELL_PKI_DIR"                => pki,
        "RUNTIME_DIRECTORY"               => runtime,
        "DEV_CELL_BOOTSTRAP_ATTEMPTS"     => attempts.to_s,
        "DEV_CELL_BOOTSTRAP_RETRY_DELAY"  => retry_delay.to_s,
        "ATTEMPT_COUNTER"                 => counter,
        "BUNDLE_JSON"                     => JSON.generate(BUNDLE),
        "OUTCOMES"                        => outcomes.join(" ")
      }

      out = IO.popen(env, ["sh", script], err: [:child, :out], unsetenv_others: true, &:read)
      status = $?
      made = File.read(counter).strip.to_i
      staged = Dir.children(runtime).sort
      [status, out, made, staged]
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    FileUtils.chmod(0o755, path)
  end

  # Reads its own invocation count from $ATTEMPT_COUNTER, picks the matching
  # word out of $OUTCOMES, and behaves accordingly. -o <file> is honored so the
  # success path stages a real body.
  def curl_stub(_outcomes)
    <<~'SH'
      #!/bin/sh
      n=$(cat "$ATTEMPT_COUNTER")
      n=$((n + 1))
      echo "$n" > "$ATTEMPT_COUNTER"

      outcome=$(echo "$OUTCOMES" | cut -d' ' -f"$n")
      [ -n "$outcome" ] || outcome=200

      # Locate -o <file> the way the script actually calls us.
      out=""
      prev=""
      for a in "$@"; do
        [ "$prev" = "-o" ] && out="$a"
        prev="$a"
      done

      if [ "$outcome" = "dns" ]; then
        echo "curl: (6) Could not resolve host: ops-hub.invalid" >&2
        exit 6
      fi

      if [ "$outcome" = "200" ] && [ -n "$out" ]; then
        printf '%s' "$BUNDLE_JSON" > "$out"
      fi
      printf '%s' "$outcome"
      exit 0
    SH
  end

  it "survives the pivot-boot DNS window instead of failing the unit" do
    # Exactly the observed shape: DNS down for the first attempts, then up.
    status, out, attempts, staged = run_bootstrap(%w[dns dns 200])

    expect(status).to be_success, "script exited #{status.exitstatus}: #{out}"
    expect(attempts).to eq(3)
    expect(out).to include("retrying in")
    expect(staged).to include("mcp_credentials.json", "gitea_credentials.json", "deploy_key", "known_hosts")
  end

  it "retries a 5xx — the platform side still coming up is the same transient" do
    status, out, attempts, = run_bootstrap(%w[503 200])

    expect(status).to be_success, "script exited #{status.exitstatus}: #{out}"
    expect(attempts).to eq(2)
    expect(out).to include("returned HTTP 503")
  end

  it "fails fast on 404 — an unprovisioned bundle is an operator answer, not a transient" do
    status, out, attempts, = run_bootstrap(%w[404 200])

    expect(status).not_to be_success
    expect(attempts).to eq(1), "404 must not be retried"
    expect(out).to include("an operator must provision one")
  end

  it "fails fast on a non-5xx client error rather than burning the retry budget" do
    status, _out, attempts, = run_bootstrap(%w[403 200])

    expect(status).not_to be_success
    expect(attempts).to eq(1)
  end

  it "gives up after the configured attempts when DNS never recovers" do
    status, out, attempts, = run_bootstrap(%w[dns dns dns], attempts: 3)

    expect(status).not_to be_success
    expect(attempts).to eq(3)
    expect(out).to include("after 3 attempts")
  end
end
