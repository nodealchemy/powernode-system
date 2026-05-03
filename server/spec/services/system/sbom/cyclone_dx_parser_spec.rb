# frozen_string_literal: true

require "rails_helper"

RSpec.describe System::Sbom::CycloneDxParser do
  describe ".parse" do
    context "with valid CycloneDX 1.5 input" do
      let(:doc) do
        {
          "bomFormat" => "CycloneDX",
          "specVersion" => "1.5",
          "components" => [
            {
              "type" => "library",
              "name" => "openssl",
              "version" => "3.0.7",
              "purl" => "pkg:deb/debian/openssl@3.0.7",
              "licenses" => [ { "license" => { "id" => "Apache-2.0" } } ]
            },
            {
              "type" => "library",
              "name" => "rails",
              "version" => "8.1.0",
              "purl" => "pkg:gem/rails@8.1.0",
              "licenses" => [ { "license" => { "id" => "MIT" } } ]
            }
          ]
        }
      end

      it "returns a Result with parsed packages" do
        result = described_class.parse(doc)

        expect(result).to be_a(System::Sbom::CycloneDxParser::Result)
        expect(result.package_count).to eq(2)
        expect(result.truncated?).to be false
        expect(result.source_format).to eq("cyclonedx-1.5")
      end

      it "uses string keys consistent with ModuleArtifact#sbom_packages" do
        packages = described_class.parse(doc).packages

        expect(packages.first.keys).to contain_exactly(
          "name", "version", "ecosystem", "purl", "license"
        )
      end

      it "extracts each component's name + version" do
        names = described_class.parse(doc).packages.map { |p| p["name"] }
        versions = described_class.parse(doc).packages.map { |p| p["version"] }

        expect(names).to eq([ "openssl", "rails" ])
        expect(versions).to eq([ "3.0.7", "8.1.0" ])
      end
    end

    context "ecosystem derivation from purl scheme" do
      [
        [ "pkg:deb/debian/openssl@3.0.7",        "deb" ],
        [ "pkg:rpm/redhat/glibc@2.34",           "rpm" ],
        [ "pkg:apk/alpine/musl@1.2.4",           "apk" ],
        [ "pkg:gem/rails@8.1.0",                 "gem" ],
        [ "pkg:rubygems/sinatra@3.0.0",          "gem" ], # alias
        [ "pkg:npm/lodash@4.17.21",              "npm" ],
        [ "pkg:pypi/django@4.2.0",               "pypi" ],
        [ "pkg:golang/github.com/go-redis@9.0",  "go" ], # alias
        [ "pkg:maven/org.apache/commons@1.0",    "maven" ],
        [ "pkg:nuget/Newtonsoft.Json@13.0",      "nuget" ],
        [ "pkg:cargo/serde@1.0",                 "cargo" ],
        [ "pkg:composer/symfony/http@6.0",       "composer" ],
        [ "pkg:oci/library/postgres@15",         "oci" ],
        [ "pkg:custom-scheme/foo@1.0",           "custom-scheme" ] # passthrough
      ].each do |purl, expected_ecosystem|
        it "maps #{purl.inspect} to ecosystem #{expected_ecosystem.inspect}" do
          doc = {
            "bomFormat" => "CycloneDX",
            "components" => [ { "name" => "x", "purl" => purl } ]
          }

          ecosystem = described_class.parse(doc).packages.first["ecosystem"]
          expect(ecosystem).to eq(expected_ecosystem)
        end
      end

      it "leaves ecosystem blank when purl is missing" do
        doc = {
          "bomFormat" => "CycloneDX",
          "components" => [ { "name" => "x", "version" => "1.0" } ]
        }

        expect(described_class.parse(doc).packages.first["ecosystem"]).to eq("")
      end

      it "leaves ecosystem blank when purl lacks pkg: prefix" do
        doc = {
          "bomFormat" => "CycloneDX",
          "components" => [ { "name" => "x", "purl" => "not-a-purl" } ]
        }

        expect(described_class.parse(doc).packages.first["ecosystem"]).to eq("")
      end
    end

    context "license extraction" do
      it "reads license.id when present" do
        doc = build_doc(licenses: [ { "license" => { "id" => "Apache-2.0" } } ])
        expect(described_class.parse(doc).packages.first["license"]).to eq("Apache-2.0")
      end

      it "falls back to license.name when id absent" do
        doc = build_doc(licenses: [ { "license" => { "name" => "Custom Corp License" } } ])
        expect(described_class.parse(doc).packages.first["license"]).to eq("Custom Corp License")
      end

      it "reads expression form" do
        doc = build_doc(licenses: [ { "expression" => "Apache-2.0 OR MIT" } ])
        expect(described_class.parse(doc).packages.first["license"]).to eq("Apache-2.0 OR MIT")
      end

      it "returns blank when licenses array is empty" do
        doc = build_doc(licenses: [])
        expect(described_class.parse(doc).packages.first["license"]).to eq("")
      end

      it "returns blank when licenses absent" do
        doc = { "bomFormat" => "CycloneDX", "components" => [ { "name" => "x" } ] }
        expect(described_class.parse(doc).packages.first["license"]).to eq("")
      end
    end

    context "edge cases" do
      it "drops components with blank name" do
        doc = {
          "bomFormat" => "CycloneDX",
          "components" => [
            { "name" => "valid", "version" => "1.0" },
            { "name" => "" },
            { "version" => "2.0" } # no name at all
          ]
        }

        expect(described_class.parse(doc).package_count).to eq(1)
      end

      it "tolerates missing version (treats as empty string)" do
        doc = {
          "bomFormat" => "CycloneDX",
          "components" => [ { "name" => "foo" } ]
        }
        package = described_class.parse(doc).packages.first

        expect(package["version"]).to eq("")
      end

      it "returns empty Result for non-CycloneDX input" do
        result = described_class.parse({ "bomFormat" => "SPDX", "components" => [] })

        expect(result.packages).to eq([])
        expect(result.source_format).to eq("unknown")
      end

      it "returns empty Result for invalid JSON string" do
        result = described_class.parse("{ not valid json }")

        expect(result.packages).to eq([])
        expect(result.truncated?).to be false
      end

      it "accepts JSON string input and parses it" do
        json = JSON.dump({
          "bomFormat" => "CycloneDX",
          "components" => [ { "name" => "x", "version" => "1.0" } ]
        })

        result = described_class.parse(json)
        expect(result.package_count).to eq(1)
      end

      it "returns empty Result for nil input" do
        expect(described_class.parse(nil).packages).to eq([])
      end

      it "returns empty Result for empty hash" do
        expect(described_class.parse({}).packages).to eq([])
      end
    end

    context "truncation at MAX_PACKAGES" do
      it "truncates when components exceed MAX_PACKAGES" do
        components = (described_class::MAX_PACKAGES + 50).times.map do |i|
          { "name" => "pkg-#{i}", "version" => "1.0" }
        end
        doc = { "bomFormat" => "CycloneDX", "components" => components }

        result = described_class.parse(doc)

        expect(result.truncated?).to be true
        expect(result.package_count).to eq(described_class::MAX_PACKAGES)
      end

      it "does not truncate at exactly MAX_PACKAGES" do
        components = described_class::MAX_PACKAGES.times.map do |i|
          { "name" => "pkg-#{i}" }
        end
        doc = { "bomFormat" => "CycloneDX", "components" => components }

        expect(described_class.parse(doc).truncated?).to be false
      end
    end
  end

  def build_doc(name: "foo", version: "1.0", purl: "pkg:gem/foo@1.0", licenses: nil)
    component = { "name" => name, "version" => version, "purl" => purl }
    component["licenses"] = licenses if licenses
    { "bomFormat" => "CycloneDX", "components" => [ component ] }
  end
end
