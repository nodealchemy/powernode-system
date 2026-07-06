# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe System::Gitops::DesiredStateParser do
  let(:work_tree) { Dir.mktmpdir("gitops-spec") }

  after { FileUtils.rm_rf(work_tree) }

  describe ".parse!" do
    it "returns ok with parsed sections" do
      File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
        templates:
          web:
            name: web
            description: Standard
        modules:
          nginx:
            name: nginx
            priority: 50
        assignments:
          host-1:nginx:
            enabled: true
            priority: 50
      YAML

      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be true
      expect(result.desired_state.templates.keys).to eq([ "web" ])
      expect(result.desired_state.modules.keys).to eq([ "nginx" ])
      expect(result.desired_state.assignments.keys).to eq([ "host-1:nginx" ])
    end

    it "returns err when fleet.yaml is missing" do
      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be false
      expect(result.error).to include("not found")
    end

    it "returns err on YAML syntax error" do
      File.write(File.join(work_tree, "fleet.yaml"), "templates:\n  - bad\n - indent")

      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be false
      expect(result.error).to include("YAML syntax error")
    end

    it "rejects files exceeding 1 MiB" do
      File.write(File.join(work_tree, "fleet.yaml"), "templates:\n" + ("  k#{rand}: v\n" * 100_000))

      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be false
      expect(result.error).to include("exceeds")
    end

    it "honors path_prefix" do
      sub = File.join(work_tree, "sub", "dir")
      FileUtils.mkdir_p(sub)
      File.write(File.join(sub, "fleet.yaml"), "templates: { web: { name: web } }")

      result = described_class.parse!(work_tree_path: work_tree, path_prefix: "sub/dir")
      expect(result.ok?).to be true
      expect(result.desired_state.templates.keys).to eq([ "web" ])
    end

    it "treats an empty fleet.yaml as a valid empty desired state" do
      File.write(File.join(work_tree, "fleet.yaml"), "")

      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be true
      expect(result.desired_state.empty?).to be true
    end

    it "parses the pools + platforms sections (declarative instance topology)" do
      File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
        pools:
          web-warm:
            name: web-warm
            node_template: web-server
            target_size: 3
            min_size: 1
            max_size: 5
        platforms:
          hub-api:
            name: hub-api
            service_role: api
            node_template: web-server
            target_replicas: 2
      YAML

      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be true
      expect(result.desired_state.pools.keys).to eq([ "web-warm" ])
      expect(result.desired_state.platforms.keys).to eq([ "hub-api" ])
      expect(result.desired_state.pools["web-warm"]["target_size"]).to eq(3)
      expect(result.desired_state.platforms["hub-api"]["target_replicas"]).to eq(2)
    end

    it "reports empty? false when only a pools section is present" do
      File.write(File.join(work_tree, "fleet.yaml"), <<~YAML)
        pools:
          web-warm:
            name: web-warm
            node_template: web-server
            target_size: 1
      YAML

      result = described_class.parse!(work_tree_path: work_tree)
      expect(result.ok?).to be true
      expect(result.desired_state.empty?).to be false
    end
  end
end
