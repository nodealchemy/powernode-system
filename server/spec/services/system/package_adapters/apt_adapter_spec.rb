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
      expect(result).to eq([[{ "name" => "libc6", "op" => ">=", "version" => "2.34" }]])
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
end
