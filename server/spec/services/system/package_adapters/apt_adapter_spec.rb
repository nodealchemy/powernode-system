# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PackageAdapters::AptAdapter do
  subject(:adapter) { described_class.new }

  describe "#parse_dependency_string" do
    it "returns [] for nil or empty input" do
      expect(adapter.parse_dependency_string(nil)).to eq([])
      expect(adapter.parse_dependency_string("")).to eq([])
      expect(adapter.parse_dependency_string("   ")).to eq([])
    end

    it "parses a single dep with version constraint" do
      result = adapter.parse_dependency_string("libc6 (>= 2.34)")
      expect(result).to eq([ [ { "name" => "libc6", "op" => ">=", "version" => "2.34" } ] ])
    end

    it "parses an AND list of bare deps" do
      result = adapter.parse_dependency_string("libssl3, libpcre2-8-0, zlib1g")
      expect(result.size).to eq(3)
      expect(result.flatten.map { |d| d["name"] }).to eq(%w[libssl3 libpcre2-8-0 zlib1g])
    end

    it "parses OR-alternatives within a single AND term" do
      result = adapter.parse_dependency_string("debconf (>= 0.5) | debconf-2.0")
      expect(result).to eq([
        [
          { "name" => "debconf", "op" => ">=", "version" => "0.5" },
          { "name" => "debconf-2.0", "op" => nil, "version" => nil }
        ]
      ])
    end

    it "strips multi-arch suffix (pkg:arch)" do
      result = adapter.parse_dependency_string("libc6:amd64 (>= 2.34)")
      expect(result.first.first["name"]).to eq("libc6")
    end

    it "handles a mix: AND + OR + version constraints" do
      result = adapter.parse_dependency_string("libc6 (>= 2.34), libssl3 (>= 3.0.0), debconf (>= 0.5) | debconf-2.0")
      expect(result.size).to eq(3)
      expect(result.last.size).to eq(2) # the OR group
    end
  end

  describe "#compare_versions" do
    it "returns 0 for equal versions" do
      expect(adapter.compare_versions("1.2.3", "1.2.3")).to eq(0)
    end

    it "returns -1 when a < b" do
      expect(adapter.compare_versions("1.2.3", "1.2.4")).to eq(-1)
    end

    it "returns 1 when a > b" do
      expect(adapter.compare_versions("1.2.4", "1.2.3")).to eq(1)
    end

    it "handles Debian epoch + revision (dpkg semantics)" do
      # 2:1.0 > 1:9.0 because epoch 2 > epoch 1
      expect(adapter.compare_versions("2:1.0", "1:9.0")).to eq(1)
      # ubuntu1 vs ubuntu2 in revision suffix
      expect(adapter.compare_versions("1.24.0-1ubuntu1", "1.24.0-1ubuntu2")).to eq(-1)
    end
  end

  describe "Packages stream parsing" do
    let(:fixture) do
      <<~PKG
        Package: nginx
        Version: 1.24.0-1ubuntu1
        Architecture: amd64
        Section: web
        Installed-Size: 412
        Size: 89432
        Depends: libc6 (>= 2.34), libssl3 (>= 3.0.0)
        Recommends: ssl-cert
        Provides: httpd
        Filename: pool/main/n/nginx/nginx_1.24.0-1ubuntu1_amd64.deb
        SHA256: abc123
        Maintainer: Ubuntu Developers <devs@example.com>
        Description: high performance web server
         nginx is a reverse proxy and origin server.

        Package: libc6
        Version: 2.39-0ubuntu8
        Architecture: amd64
        Section: libs
        Installed-Size: 13340
        Size: 3201432
        Filename: pool/main/g/glibc/libc6_2.39-0ubuntu8_amd64.deb
        SHA256: def456
        Description: GNU C Library

      PKG
    end

    it "yields one ParsedPackage per paragraph" do
      packages = []
      adapter.send(:parse_packages_stream, fixture) do |fields|
        packages << adapter.send(:to_parsed_package, fields, default_arch: "amd64")
      end

      expect(packages.size).to eq(2)
      nginx = packages.find { |p| p.name == "nginx" }
      libc = packages.find { |p| p.name == "libc6" }
      expect(nginx.version).to eq("1.24.0-1ubuntu1")
      expect(nginx.installed_size_bytes).to eq(412 * 1024) # KB → bytes
      expect(nginx.download_size_bytes).to eq(89432)
      expect(nginx.depends.size).to eq(2)
      expect(nginx.recommends.first.first["name"]).to eq("ssl-cert")
      expect(nginx.provides.first.first["name"]).to eq("httpd")
      expect(libc.version).to eq("2.39-0ubuntu8")
      expect(libc.depends).to eq([])
    end

    it "produces ParsedPackage struct with normalized columns" do
      packages = []
      adapter.send(:parse_packages_stream, fixture) do |fields|
        packages << adapter.send(:to_parsed_package, fields, default_arch: "amd64")
      end
      nginx = packages.first
      expect(nginx).to be_a(System::PackageAdapters::Base::ParsedPackage)
      expect(nginx.summary).to eq("high performance web server")
      expect(nginx.maintainer).to include("Ubuntu Developers")
    end
  end

  # Regression: a partial upstream fetch (some configured architectures fetch,
  # others time out / 5xx) MUST NOT be reported as an authoritative package set.
  # Historically the adapter did `missing << ...; next` on any failure and only
  # raised when EVERY (component,arch) failed, so a flaky fetch silently dropped
  # whole architectures — which the sync service then tried to mass-obsolete.
  # A transport failure must abort; a genuine 404 (absent combo) is tolerated.
  describe "#sync_metadata partial-fetch handling" do
    let(:repo) do
      instance_double(
        System::PackageRepository,
        base_url: "http://mirror.test/ubuntu",
        suite: "noble",
        components: [ "main" ],
        signing_key_armor: nil
      )
    end

    let(:packages_blob) do
      <<~PKG
        Package: nginx
        Version: 1.24.0-1ubuntu1
        Architecture: amd64
        Filename: pool/main/n/nginx/nginx_1.24.0-1ubuntu1_amd64.deb
        SHA256: abc123

      PKG
    end

    # Route http_get by URL: serve InRelease + the uncompressed amd64 Packages,
    # 404 the compressed variants (forces the plain-Packages fallback), and make
    # `fail_arch` fail every variant with `fail_status` (nil == network/timeout).
    def stub_upstream(fail_arch:, fail_status:)
      err = System::PackageAdapters::Base::FetchError
      allow(adapter).to receive(:http_get) do |url, **_kw|
        if url.end_with?("/dists/noble/InRelease")
          "Suite: noble\n"
        elsif (m = url.match(%r{/binary-([a-z0-9]+)/Packages(\.xz|\.gz)?\z}))
          arch = m[1]
          compressed = m[2]
          if arch == fail_arch
            raise err.new("simulated failure for #{arch}", status: fail_status)
          elsif compressed
            raise err.new("no #{compressed} variant", status: 404)
          else
            arch == "amd64" ? packages_blob : "\n"
          end
        else
          raise err.new("unexpected #{url}", status: 404)
        end
      end
    end

    it "raises rather than silently dropping an arch on a transport (5xx) failure" do
      stub_upstream(fail_arch: "arm64", fail_status: 503)
      expect do
        adapter.sync_metadata(repository: repo, architectures: %w[amd64 arm64]) { |_p| }
      end.to raise_error(System::PackageAdapters::Base::FetchError, /arm64/)
    end

    it "raises on a network/timeout failure (nil status)" do
      stub_upstream(fail_arch: "arm64", fail_status: nil)
      expect do
        adapter.sync_metadata(repository: repo, architectures: %w[amd64 arm64]) { |_p| }
      end.to raise_error(System::PackageAdapters::Base::FetchError)
    end

    it "tolerates a genuinely-absent (404) arch and yields only what it fetched" do
      stub_upstream(fail_arch: "arm64", fail_status: 404)
      yielded = []
      count = adapter.sync_metadata(repository: repo, architectures: %w[amd64 arm64]) { |p| yielded << p }
      expect(yielded.map(&:name)).to eq([ "nginx" ])
      expect(count).to eq(1)
    end
  end

  describe "Base::FetchError#not_found?" do
    let(:err_class) { System::PackageAdapters::Base::FetchError }

    it "is true for 404/410 (definitively absent) and false for transport/5xx/network" do
      expect(err_class.new("x", status: 404).not_found?).to be(true)
      expect(err_class.new("x", status: 410).not_found?).to be(true)
      expect(err_class.new("x", status: 503).not_found?).to be(false)
      expect(err_class.new("x", status: 429).not_found?).to be(false)
      expect(err_class.new("x", status: nil).not_found?).to be(false)
    end
  end

  describe "#http_get resilience" do
    let(:conn) { instance_double(Faraday::Connection) }

    before { allow(Faraday).to receive(:new).and_return(conn) }

    it "retries a transient network failure, then returns the body" do
      calls = 0
      allow(conn).to receive(:get) do
        calls += 1
        raise Faraday::TimeoutError if calls < 2

        instance_double(Faraday::Response, status: 200, body: "OK")
      end
      allow(adapter).to receive(:sleep) # skip real backoff
      expect(adapter.send(:http_get, "http://mirror.test/x")).to eq("OK")
      expect(calls).to eq(2)
    end

    it "does NOT retry a definitive 404 and surfaces the status" do
      calls = 0
      allow(conn).to receive(:get) do
        calls += 1
        instance_double(Faraday::Response, status: 404, body: "")
      end
      allow(adapter).to receive(:sleep)
      expect { adapter.send(:http_get, "http://mirror.test/x") }
        .to raise_error(System::PackageAdapters::Base::FetchError) { |e| expect(e.status).to eq(404) }
      expect(calls).to eq(1)
    end
  end
end
