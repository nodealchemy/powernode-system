# frozen_string_literal: true

require "rails_helper"
require "open3"

# IMP-24d473c6f448 (F1/F3) — the planner's reader (System::ModuleBuildScriptAttribution)
# and the build-inputs hash's reader (scripts/module-build/stage15-arm.py) are two
# implementations of one grammar. If they disagree, the planner targets a module
# whose skip hash never moves (the wrong SKIP this whole change exists to prevent),
# or the reverse. This runs both over the REAL stage15.sh and over the awkward
# forms, and fails on any divergence.
RSpec.describe "stage15 arm reader parity (Ruby planner vs stage15-arm.py)" do
  let(:scripts_dir) { File.expand_path("../../../../scripts/module-build", __dir__) }
  let(:real) { File.binread("#{scripts_dir}/stage15.sh").force_encoding("UTF-8") }
  let(:reader) { System::ModuleBuildScriptAttribution }

  def py(script, *args)
    out, err, status = Open3.capture3("python3", "#{scripts_dir}/stage15-arm.py", *args, stdin_data: script, binmode: true)
    [ out, err, status.exitstatus ]
  end

  def py_slugs(script)
    out, _err, rc = py(script, "--slugs")
    rc.zero? ? out.split("\n") : rc
  end

  def rb_slugs(script)
    reader.parse(script).slugs.to_a.sort
  rescue reader::ParseError
    2
  end

  describe "against the real stage15.sh" do
    it "finds the same set of arms" do
      expect(py_slugs(real)).to eq(rb_slugs(real))
      expect(rb_slugs(real)).to include("powernode-hub-backend", "vault", "module-forge")
    end

    it "extracts byte-identical arm text for every slug" do
      reader.parse(real).slugs.each do |slug|
        out, _err, rc = py(real, "--dump", slug)
        expect(rc).to eq(0), "python found no arm for #{slug}"
        expect(out.b).to eq(reader.parse(real).text_for(slug).b), "arm text differs for #{slug}"
      end
    end

    it "reports the same helper edges (which scripts each arm calls)" do
      helpers = Dir.children(scripts_dir).reject { |f| f == "stage15.sh" }.sort
      parsed = reader.parse(real)

      parsed.slugs.each do |slug|
        out, _err, rc = py(real, slug, *helpers)
        expect(rc).to eq(0)
        py_called = out.lines.filter_map { |l| l.split(" ", 2).last.strip if l.start_with?("helper ") }

        rb_called = helpers.select do |h|
          reader.modules_for(changed_paths: [ "scripts/module-build/#{h}" ], base_stage15: nil, head_stage15: real).include?(slug)
        end
        expect(py_called).to eq(rb_called), "helper edges differ for #{slug}"
      end
    end

    it "gives a module with no arm exit 1 (nothing to fold)" do
      expect(py(real, "postgres-primary").last).to eq(1)
    end
  end

  describe "against the awkward forms" do
    {
      "quoted patterns" => %Q~case "$MODULE" in\n  "vault")\n    echo v\n    ;;\n  'gh')\n    echo g\n    ;;\nesac\n~,
      "space-separated alternatives" => %Q~case "$MODULE" in\n  a | b )\n    echo x\n    ;;\nesac\n~,
      "leading paren" => %Q~case "$MODULE" in\n  (a)\n    echo x\n    ;;\nesac\n~,
      "esac ;; on one line" => %Q~case "$MODULE" in\n  a)\n    case "$X" in\n      1) y=1 ;;\n    esac ;;\n  b) echo b ;;\nesac\n~,
      "spaced heredoc" => %Q~case "$MODULE" in\n  a)\n    cat << EOF\n  b) x ;;\nEOF\n    ;;\n  c) echo c ;;\nesac\n~,
      "quoted spaced heredoc" => %Q~case "$MODULE" in\n  a)\n    cat << 'EOF'\n  b) x ;;\nEOF\n    ;;\n  c) echo c ;;\nesac\n~,
      "heredoc with dash" => %Q~case "$MODULE" in\n  a)\n    cat <<-EOF\n  b) x ;;\n  EOF\n    ;;\n  c) echo c ;;\nesac\n~,
      "spaced append" => %Q~case "$MODULE" in\n  a)\n    ruby -e 'm << spec.name'\n    ;;\n  c) echo c ;;\nesac\n~,
      "wildcard arm" => %Q~case "$MODULE" in\n  a) echo a ;;\n  *) echo other ;;\nesac\n~,
      "glob alongside a slug" => %Q~case "$MODULE" in\n  a|runtime-*) echo a ;;\nesac\n~,
      "two dispatch blocks" => %Q~case "$MODULE" in\n  a|b) x=1 ;;\nesac\ncase "$MODULE" in\n  a)\n    echo a\n    ;;\nesac\n~,
      "CRLF line endings" => %Q~case "$MODULE" in\r\n  a)\r\n    echo a\r\n    ;;\r\nesac\r\n~,
      "non-ASCII bytes in an arm" => %Q~case "$MODULE" in\n  a)\n    echo "café — ok"\n    ;;\nesac\n~,
      "unbalanced (missing esac)" => %Q~case "$MODULE" in\n  a) echo a ;;\n~,
      "esac with no case" => "esac\n",
      "no dispatch at all" => "echo hi\n"
    }.each do |name, script|
      it "agrees on #{name}" do
        expect(py_slugs(script)).to eq(rb_slugs(script))

        next unless rb_slugs(script).is_a?(Array)

        rb_slugs(script).each do |slug|
          out, _err, rc = py(script, "--dump", slug)
          expect(rc).to eq(0)
          expect(out.b).to eq(reader.parse(script).text_for(slug).b), "arm text differs for #{slug}"
        end
      end
    end
  end
end
