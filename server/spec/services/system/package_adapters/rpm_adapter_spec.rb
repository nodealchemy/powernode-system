# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::PackageAdapters::RpmAdapter do
  subject(:adapter) { described_class.new }

  describe "#compare_versions (rpmvercmp port)" do
    it "returns 0 for equal versions" do
      expect(adapter.compare_versions("3.0.13", "3.0.13")).to eq(0)
    end

    it "handles simple numeric comparisons" do
      expect(adapter.compare_versions("3.0.13", "3.0.14")).to eq(-1)
      expect(adapter.compare_versions("3.0.14", "3.0.13")).to eq(1)
    end

    it "treats tilde as sorting BEFORE empty (pre-release semantics)" do
      # 1.0.0~rc1 < 1.0.0 because tilde indicates pre-release
      expect(adapter.compare_versions("1.0.0~rc1", "1.0.0")).to eq(-1)
      expect(adapter.compare_versions("1.0.0", "1.0.0~rc1")).to eq(1)
    end

    it "treats caret as sorting AFTER empty (post-release snapshot)" do
      # 1.0.0^20230401 > 1.0.0 because caret indicates a snapshot AFTER base
      expect(adapter.compare_versions("1.0.0", "1.0.0^rc1")).to eq(-1)
      expect(adapter.compare_versions("1.0.0^rc1", "1.0.0")).to eq(1)
    end

    it "uses numeric (not lexical) comparison for digit runs" do
      expect(adapter.compare_versions("1.0.10", "1.0.9")).to eq(1)
      expect(adapter.compare_versions("1.0.2", "1.0.10")).to eq(-1)
    end

    it "compares alpha runs lexically" do
      expect(adapter.compare_versions("1.0.a", "1.0.b")).to eq(-1)
      expect(adapter.compare_versions("1.0.b", "1.0.a")).to eq(1)
    end

    it "treats longer prefix as greater when both share matching segments" do
      # 1.0 < 1.0.0 because the 1.0.0 side has an extra ".0" segment
      expect(adapter.compare_versions("1.0", "1.0.0")).to eq(-1)
      expect(adapter.compare_versions("1.0.0", "1.0")).to eq(1)
    end

    it "splits epoch:version-release correctly" do
      # Epoch 2 trumps any version on the no-epoch side (default epoch=0)
      expect(adapter.compare_versions("2:1.0-1", "0:9.0-1")).to eq(1)
      expect(adapter.compare_versions("0:1.0-1", "2:0.1-1")).to eq(-1)
    end

    it "compares release qualifiers when version is equal" do
      expect(adapter.compare_versions("1.0-1.fc40", "1.0-2.fc40")).to eq(-1)
      expect(adapter.compare_versions("1.0-2.fc40", "1.0-1.fc40")).to eq(1)
    end
  end

  describe "primary.xml parsing" do
    let(:primary_xml) do
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <metadata xmlns="http://linux.duke.edu/metadata/common"
                  xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="1">
          <package type="rpm">
            <name>openssl</name>
            <arch>x86_64</arch>
            <version epoch="1" ver="3.0.13" rel="1.fc40"/>
            <summary>Cryptography Toolkit</summary>
            <description>OpenSSL is a toolkit...</description>
            <url>https://www.openssl.org/</url>
            <size package="2000000" installed="5000000"/>
            <location href="Packages/o/openssl-3.0.13-1.fc40.x86_64.rpm"/>
            <checksum type="sha256">deadbeef</checksum>
            <format>
              <rpm:license>Apache-2.0</rpm:license>
              <rpm:group>System Environment/Libraries</rpm:group>
              <rpm:requires>
                <rpm:entry name="libcrypt.so.2()(64bit)"/>
                <rpm:entry name="glibc" flags="GE" ver="2.34"/>
              </rpm:requires>
              <rpm:provides>
                <rpm:entry name="openssl(api)"/>
              </rpm:provides>
            </format>
          </package>
        </metadata>
      XML
    end

    it "parses package metadata + dependency normalization" do
      pkgs = adapter.send(:parse_primary_xml, primary_xml)
      expect(pkgs.size).to eq(1)
      f = pkgs.first
      expect(f[:name]).to eq("openssl")
      expect(f[:arch]).to eq("x86_64")
      expect(f[:version]).to eq("3.0.13")
      expect(f[:release]).to eq("1.fc40")
      expect(f[:epoch]).to eq("1")
      expect(f[:installed_size_bytes]).to eq(5000000)
      expect(f[:download_size_bytes]).to eq(2000000)
      expect(f[:license]).to eq("Apache-2.0")
      # Requires: capability dep (no op/version) + version constraint
      expect(f[:requires].size).to eq(2)
      expect(f[:requires].first.first["name"]).to eq("libcrypt.so.2()(64bit)")
      expect(f[:requires].last.first).to include("name" => "glibc", "op" => ">=", "version" => "2.34")
      expect(f[:provides].first.first["name"]).to eq("openssl(api)")
    end
  end
end
