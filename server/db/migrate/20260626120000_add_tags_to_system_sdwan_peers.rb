# frozen_string_literal: true

# D8 tag-write path — give SDWAN peers a `tags` label set so firewall
# rules with a { "tag": "<label>" } selector resolve to the tagged peers
# (Sdwan::SelectorResolver). Until this column existed, every tag matched
# no peers and the firewall failed CLOSED (denied); with it, tags work.
class AddTagsToSystemSdwanPeers < ActiveRecord::Migration[8.1]
  def change
    add_column :system_sdwan_peers, :tags, :string, array: true, default: [], null: false
    add_index :system_sdwan_peers, :tags, using: :gin
  end
end
