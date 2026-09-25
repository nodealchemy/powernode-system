# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("..", "extensions", "system", "server", "db", "migrate",
                        "20260925140000_refresh_system_canonical_agent_content").to_s

# The system agents' seeded text reaches existing rows (every seed run, and the
# data migration for installs whose seeds never re-run) without overwriting what
# an operator edited (db/seeds/content/canonical_agent_content.rb).
RSpec.describe "system canonical agent content" do
  content = System::Seeds::CanonicalAgentContent
  stamp_key = Ai::Agents::CanonicalContentRefresh::STAMP_KEY
  seed_files = %w[
    fleet_autonomy_agent.rb system_concierge_agent.rb system_runtime_manager_agent.rb
    system_cve_responder_agent.rb system_sdwan_manager_agent.rb
  ].freeze

  let!(:account)  { create(:account, name: "Powernode Admin") }
  let!(:user)     { create(:user, account: account, email: "admin@powernode.org") }
  let!(:provider) { create(:ai_provider, account: account, provider_type: "anthropic", is_active: true) }

  define_method(:seed_all!) do
    silence_warnings do
      seed_files.each { |file| load Rails.root.join("..", "extensions", "system", "server", "db", "seeds", file) }
    end
  end

  def global(slug) = Ai::Agent.global.find_by!(slug: slug)

  def age!(slug, description:)
    agent = global(slug)
    agent.update_columns(description: description, mcp_metadata: agent.mcp_metadata.except(stamp_key))
  end

  content::AGENTS.each do |slug, entry|
    it "gives #{slug} exactly one routing sentence and never lists the current text as previous" do
      sentences = entry[:description].split(/(?<=[.!?])\s+/)
      expect(sentences.count { |sentence| sentence.match?(/\AUse (?:this agent )?when\b/i) }).to eq(1)
      expect(entry[:previous][:description]).not_to include(entry[:description])
    end
  end

  it "seeds and stamps every catalog entry, and keeps an operator's edit across a re-seed" do
    seed_all!
    content::AGENTS.each do |slug, entry|
      expect(global(slug).description).to eq(entry[:description]), slug
      expect(global(slug).mcp_metadata.dig(stamp_key, "system_prompt", "digest")).to be_present, slug
    end

    global("sdwan-manager").update!(description: "Our own SDWAN agent.")
    cve = global("cve-responder")
    cve.update!(system_prompt: "Our own CVE persona.")

    expect { seed_all! }.to output(/sdwan-manager: kept operator-edited description/).to_stdout

    expect(global("sdwan-manager").description).to eq("Our own SDWAN agent.")
    expect(global("cve-responder").system_prompt).to eq("Our own CVE persona.")
  end

  it "migrates unedited rows, skips an edited one, and reverts on down" do
    seed_all!
    age!("fleet-autonomy", description: content.previous("fleet-autonomy")[:description].first)
    age!("runtime-manager", description: "An operator's runtime agent.")
    migration = RefreshSystemCanonicalAgentContent.new

    expect { migration.migrate(:up) }.to output(/runtime-manager: kept operator-edited description/).to_stdout
    expect(global("fleet-autonomy").description).to eq(content.description("fleet-autonomy"))
    expect(global("runtime-manager").description).to eq("An operator's runtime agent.")

    expect { migration.migrate(:down) }.to output.to_stdout
    expect(global("fleet-autonomy").description).to eq(content.previous("fleet-autonomy")[:description].first)
  end
end
