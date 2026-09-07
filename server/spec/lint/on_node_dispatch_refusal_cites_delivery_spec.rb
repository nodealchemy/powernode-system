# frozen_string_literal: true

require "rails_helper"

# IMP-a501f841ffce. System::NodeInstance#on_node_dispatch_refusal's docstring
# makes a CAUSAL claim — "an on-node task is only ever executed by the agent
# polling pending rows, so one created for an instance with no live agent sits
# at pending / progress 0 until the worker janitor cancels it 48 hours later".
#
# The claim is true. It was filed as suspect because the reader could not check
# it: the docstring asserted the mechanism and cited nothing, while
# ExecutionDispatcher::COMMAND_REGISTRY appeared to map sync_modules and
# apply_config to SERVER-side runtime classes. Resolving which of those was
# real took an independent review and a source audit, twice.
#
# WHY A LINT AND NOT JUST A BETTER COMMENT. This subsystem's recurring defect is
# a confident sentence with no way to check it — the same shape produced the
# offer this spec closes, and its predecessor, and the retired dispatch spine's
# own header. A one-time rewrite decays; the next author rephrases the claim and
# the citation goes with it. Pinning the EVIDENCE rather than the prose makes
# the docstring cite its sources for as long as it makes the assertion.
#
# Deliberately loose about wording and strict about identifiers: it matches the
# names a reader would grep for, not a sentence.
RSpec.describe "NodeInstance#on_node_dispatch_refusal cites its delivery evidence", type: :lint do
  # Anchored on __dir__, NOT Rails.root. Rails.root is the CORE app (the suite
  # runs from /home/pnadmin/work/server), so a Rails.root-relative hop into the
  # extension resolves only while the extension sits at exactly
  # $RAILS_ROOT/../extensions/system — in a worktree it raises Errno::ENOENT
  # instead of producing this file's carefully-worded failure. Every sibling in
  # spec/lint/ uses __dir__, and gate_composed_task_categories_spec.rb warns
  # about the Rails.root form by name.
  let(:extension_server_root) { File.expand_path("../..", __dir__) }
  let(:source) { File.read(File.join(extension_server_root, "app", "models", "system", "node_instance.rb")) }

  # The docstring: everything between the IMP marker that opens it and the
  # `def`. Scoped so an unrelated mention elsewhere in this 1000-line model
  # cannot satisfy the assertions below.
  let(:docstring) do
    body = source[/^\s*# IMP-fb05226e89cb.*?(?=^\s*def on_node_dispatch_refusal)/m]
    expect(body).to be_present,
      "could not locate the #on_node_dispatch_refusal docstring — if it was restructured, " \
      "re-anchor this spec rather than deleting it; the claim still needs its citation"
    body
  end

  it "names the endpoint that actually delivers a task to an agent" do
    # THE load-bearing fact. Delivery is NodeApi::StatusController#pending_tasks
    # reading current_instance.tasks with a status-only filter — which is why an
    # instance with no live agent never has its rows collected, and why the
    # claim holds.
    expect(docstring).to match(/pending_tasks/),
      "the docstring asserts that only the agent executes an on-node task but does not name " \
      "NodeApi::StatusController#pending_tasks, the endpoint that serves it. Without that " \
      "pointer the claim cannot be checked, which is exactly how it came to be disputed."
  end

  it "names the janitor threshold it attributes the 48 hours to" do
    expect(docstring).to match(/UNRUNNABLE_THRESHOLD|SystemTaskReaperJob/),
      "the docstring states a 48-hour cancellation without naming the constant or the job " \
      "that owns it, so a reader cannot tell whether 48h is current or stale."
  end

  # THE TWO ABOVE PIN THAT THE NAMES APPEAR. These pin that they RESOLVE, which
  # is the rot mode one level removed: #pending_tasks could be renamed and the
  # docstring would keep name-dropping it, green, with a dangling citation. A
  # citation that does not resolve is worse than none — it spends the reader's
  # trust and then wastes their time.
  it "cites a #pending_tasks that still exists" do
    controller = File.join(
      extension_server_root, "app", "controllers", "api", "v1", "system", "node_api", "status_controller.rb"
    )
    expect(File.read(controller)).to match(/def pending_tasks/),
      "the docstring cites NodeApi::StatusController#pending_tasks, which no longer exists at " \
      "#{controller}. Re-point the citation at whatever now serves an agent its pending rows."
  end

  it "cites an UNRUNNABLE_THRESHOLD that still exists" do
    reaper = File.expand_path("../worker/app/jobs/system_task_reaper_job.rb", extension_server_root)
    expect(File.read(reaper)).to match(/UNRUNNABLE_THRESHOLD\s*=/),
      "the docstring attributes its 48 hours to SystemTaskReaperJob::UNRUNNABLE_THRESHOLD, which " \
      "is not defined at #{reaper}. The number in the docstring is then unsourced."
  end
end
