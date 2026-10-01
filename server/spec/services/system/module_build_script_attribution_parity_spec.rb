# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tempfile"

# IMP-24d473c6f448 (F1/F3) — the planner's reader (System::ModuleBuildScriptAttribution)
# and the build-inputs hash's reader (scripts/module-build/stage15-arm.py) are two
# implementations of one grammar. If they disagree, the planner targets a module
# whose skip hash never moves (the wrong SKIP this whole change exists to prevent),
# or the reverse. This runs both over the REAL stage15.sh and over the awkward
# forms, and fails on any divergence.
RSpec.describe "stage15 arm reader parity (Ruby planner vs stage15-arm.py)" do
  let(:scripts_dir) { File.expand_path("../../../../scripts/module-build", __dir__) }
  let(:real) { File.binread("#{scripts_dir}/stage15.sh").force_encoding("UTF-8") }
  let(:real_list) { File.read("#{scripts_dir}/needs-parent-modules.sh") }
  let(:reader) { System::ModuleBuildScriptAttribution }

  # IMP-c19b10a942d7: both readers take the needs-parent list (the text of
  # needs-parent-modules.sh) alongside the script; python reads it from a file.
  def py(script, *args, list: nil)
    argv = []
    if list
      @list_file ||= Tempfile.create([ "needs-parent", ".sh" ]).tap { |f| f.write(list); f.flush }
      argv += [ "--needs-parent-modules", @list_file.path ]
    end
    out, err, status = Open3.capture3("python3", "#{scripts_dir}/stage15-arm.py", *argv, *args, stdin_data: script, binmode: true)
    [ out, err, status.exitstatus ]
  end

  after do
    if @list_file
      @list_file.close
      File.unlink(@list_file.path)
      @list_file = nil
    end
  end

  def py_slugs(script, list: nil)
    out, _err, rc = py(script, "--slugs", list: list)
    rc.zero? ? out.split("\n") : rc
  end

  def rb_slugs(script, list: nil)
    reader.parse(script, needs_parent: reader.needs_parent_modules(list)).slugs.to_a.sort
  rescue reader::ParseError
    2
  end

  def rb_text(script, slug, list: nil)
    reader.parse(script, needs_parent: reader.needs_parent_modules(list)).text_for(slug)
  end

  describe "against the real stage15.sh" do
    it "finds the same set of arms" do
      expect(py_slugs(real, list: real_list)).to eq(rb_slugs(real, list: real_list))
      expect(rb_slugs(real, list: real_list)).to include("powernode-hub-backend", "vault", "module-forge")
    end

    it "reads the same needs-parent list out of the real needs-parent-modules.sh" do
      out, _err, rc = py(real, "--needs-parent-list", list: real_list)
      expect(rc).to eq(0)
      expect(out.split("\n")).to eq(reader.needs_parent_modules(real_list))
      expect(out.split("\n")).to contain_exactly(
        "powernode-hub-backend", "powernode-hub-worker", "powernode-hub-frontend", "powernode-extension-system"
      )
    end

    it "extracts byte-identical arm text for every slug" do
      rb_slugs(real, list: real_list).each do |slug|
        out, _err, rc = py(real, "--dump", slug, list: real_list)
        expect(rc).to eq(0), "python found no arm for #{slug}"
        expect(out.b).to eq(rb_text(real, slug, list: real_list).b), "arm text differs for #{slug}"
      end
    end

    it "folds the needs-parent shared block into exactly the listed modules, on both sides" do
      # The BEGIN marker is the one string only the block's text can carry: a
      # listed module's arm also names /tmp/parent-build-info.json, so that path
      # would not tell the block apart from the arm.
      marker = "# --- BEGIN needs-parent shared block ---"
      listed = reader.needs_parent_modules(real_list)
      expect(listed).not_to be_empty
      rb_slugs(real, list: real_list).each do |slug|
        out, _err, _rc = py(real, "--dump", slug, list: real_list)
        expectation = listed.include?(slug) ? :to : :not_to
        expect(out).send(expectation, include(marker))
        expect(rb_text(real, slug, list: real_list)).send(expectation, include(marker))
      end
    end

    it "reports the same helper edges (which scripts each arm calls)" do
      # needs-parent-modules.sh is the list both readers take, not a helper: a
      # change to it is compared as a list change (modules_for needs a base copy
      # for that), so it is not a helper edge on either side.
      helpers = Dir.children(scripts_dir).reject { |f| f == "stage15.sh" || f == "needs-parent-modules.sh" }.sort

      rb_slugs(real, list: real_list).each do |slug|
        out, _err, rc = py(real, slug, *helpers, list: real_list)
        expect(rc).to eq(0)
        py_called = out.lines.filter_map { |l| l.split(" ", 2).last.strip if l.start_with?("helper ") }

        rb_called = helpers.select do |h|
          reader.modules_for(changed_paths: [ "scripts/module-build/#{h}" ], base_stage15: nil, head_stage15: real,
                             base_needs_parent: nil, head_needs_parent: real_list).include?(slug)
        end
        expect(py_called).to eq(rb_called), "helper edges differ for #{slug}"
      end
    end

    it "gives a module with no arm exit 1 (nothing to fold)" do
      expect(py(real, "postgres-primary", list: real_list).last).to eq(1)
    end

    it "refuses the real stage15.sh without its needs-parent list, on both sides (a block nobody owns)" do
      expect(py_slugs(real)).to eq(2)
      expect(rb_slugs(real)).to eq(2)
    end
  end

  describe "against the awkward forms with a needs-parent list" do
    let(:list) { "NEEDS_PARENT_MODULES=\"\na\nz\n\"\n" }
    let(:block) { "# --- BEGIN needs-parent shared block ---\nif [ \"$needs_parent\" = \"1\" ]; then\n  case \"$host\" in\n    gh) u=1 ;;\n  esac\nfi\n# --- END needs-parent shared block ---\n" }
    let(:dispatch) { %Q~case "$MODULE" in\n  a)\n    echo a\n    ;;\n  b) echo b ;;\nesac\n~ }

    {
      "block before the dispatch" => ->(b, d) { b + d },
      "block after the dispatch" => ->(b, d) { d + b },
      "block with a heredoc holding a fake END marker" => ->(_b, d) { "# --- BEGIN needs-parent shared block ---\ncat <<'EOF'\n# --- END needs-parent shared block ---\nEOF\n# --- END needs-parent shared block ---\n" + d },
      "no block although slugs are listed" => ->(_b, d) { d },
      "BEGIN with no END" => ->(b, d) { b.sub("# --- END needs-parent shared block ---\n", "") + d },
      "END with no BEGIN" => ->(b, d) { b.sub("# --- BEGIN needs-parent shared block ---\n", "") + d },
      "two blocks" => ->(b, d) { b + d + b },
      "BEGIN inside an arm" => ->(_b, d) { d.sub("    echo a\n", "    # --- BEGIN needs-parent shared block ---\n    echo a\n    # --- END needs-parent shared block ---\n") },
      "BEGIN inside a non-dispatch case" => ->(_b, d) { "case \"$X\" in\n  1)\n    # --- BEGIN needs-parent shared block ---\n    ;;\nesac\n# --- END needs-parent shared block ---\n" + d },
      "list with a non-slug token" => ->(b, d) { b + d }
    }.each do |name, build|
      it "agrees on #{name}" do
        script = build.call(block, dispatch)
        this_list = name.start_with?("list with") ? "NEEDS_PARENT_MODULES=\"\na\n$(x)\n\"\n" : list
        expect(py_slugs(script, list: this_list)).to eq(rb_slugs(script, list: this_list))

        next unless rb_slugs(script, list: this_list).is_a?(Array)

        rb_slugs(script, list: this_list).each do |slug|
          out, _err, rc = py(script, "--dump", slug, list: this_list)
          expect(rc).to eq(0)
          expect(out.b).to eq(rb_text(script, slug, list: this_list).b), "text differs for #{slug}"
        end
      end
    end

    it "agrees that a block with no list is unreadable" do
      expect(py_slugs(block + dispatch)).to eq(2)
      expect(rb_slugs(block + dispatch)).to eq(2)
    end

    it "agrees that a listed slug with no arm still owns the block" do
      script = block + dispatch
      expect(py_slugs(script, list: list)).to eq(%w[a b z])
      out, _err, rc = py(script, "--dump", "z", list: list)
      expect(rc).to eq(0)
      expect(out).to eq(block)
      expect(rb_text(script, "z", list: list)).to eq(block)
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
