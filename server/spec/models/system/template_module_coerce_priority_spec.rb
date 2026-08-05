# frozen_string_literal: true

require "rails_helper"

# The `priority` contract itself, stated once where the column lives.
#
# Both write surfaces (Api::V1::System::TemplateModulesController and
# SystemFleetTool's assign/update actions) used `params[:priority].to_i`
# independently, so the contract existed in neither of them. It is defined here
# now and rendered differently by each — 422 vs error_result — with the
# surface behaviour pinned in their own specs.
#
# This spec exists separately because the nil clause is NOT reachable from
# either surface: both drop absent keys before calling, so nothing at the
# surface level can pin "nil stays nil". It is still part of the contract, and
# the reason it matters is written into the method.
RSpec.describe System::TemplateModule, ".coerce_priority!" do
  it "leaves nil alone rather than reading it as 0" do
    # The column default (0) applies at INSERT only. Coercing a missing key to
    # 0 would demote an existing join to the LOWEST priority on an edit that
    # never mentioned priority.
    expect(described_class.coerce_priority!(nil)).to be_nil
  end

  it "passes an integer through" do
    expect(described_class.coerce_priority!(9)).to eq(9)
  end

  it "accepts an integer-looking string, which HTTP and JSON clients send" do
    expect(described_class.coerce_priority!("7")).to eq(7)
    expect(described_class.coerce_priority!(" 7 ")).to eq(7)
    expect(described_class.coerce_priority!("-3")).to eq(-3)
  end

  it "refuses a string that is not an integer, rather than returning 0" do
    expect { described_class.coerce_priority!("abc") }
      .to raise_error(ArgumentError, /priority must be an integer/)
  end

  it "refuses a partly-numeric string" do
    expect { described_class.coerce_priority!("7abc") }.to raise_error(ArgumentError)
    expect { described_class.coerce_priority!("") }.to raise_error(ArgumentError)
  end

  it "refuses a float rather than truncating it" do
    # 2.7.to_i is 2 — the same silent wrong answer as "abc" becoming 0.
    expect { described_class.coerce_priority!(2.7) }.to raise_error(ArgumentError)
  end

  it "refuses non-scalars, which have no #to_i at all" do
    expect { described_class.coerce_priority!({ "n" => 1 }) }.to raise_error(ArgumentError)
    expect { described_class.coerce_priority!([ 1 ]) }.to raise_error(ArgumentError)
    expect { described_class.coerce_priority!(true) }.to raise_error(ArgumentError)
  end

  it "names what it got, so the refusal is actionable" do
    expect { described_class.coerce_priority!("abc") }.to raise_error(/got "abc"/)
    expect { described_class.coerce_priority!({ "n" => 1 }) }.to raise_error(/got .*Hash/)
  end

  # RANGE is the model's job, not the coercion's — one owner per concern. A
  # negative parses here and is refused by the numericality validation with its
  # own message.
  it "parses a negative and leaves the range check to validation" do
    expect(described_class.coerce_priority!("-3")).to eq(-3)

    # Built with real associations on purpose: TemplateModule delegates
    # `account` to node_template, so validating a bare .new raises
    # DelegationError before the numericality check is ever reached.
    account  = create(:account)
    platform = create(:system_node_platform, account: account)
    join = described_class.new(
      node_template: create(:system_node_template, account: account, node_platform: platform),
      node_module: create(:system_node_module, account: account, node_platform: platform,
                          category: create(:system_node_module_category, account: account),
                          name: "range-check-#{SecureRandom.hex(3)}"),
      priority: -3
    )

    expect(join).not_to be_valid
    expect(join.errors[:priority].join).to match(/greater than or equal to 0/)
  end
end
