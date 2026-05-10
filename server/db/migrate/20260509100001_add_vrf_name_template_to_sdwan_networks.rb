# frozen_string_literal: true

# Adds the per-network template that the platform uses to derive a Linux
# VRF name for each host that joins the network. Default carries an
# 8-char slice of the network handle so the resulting interface name
# stays under the 15-char IFNAMSIZ kernel limit when prefixed with
# "sdwan-".
#
# Phase N1a of the in-house encrypted mesh overlay roadmap.
class AddVrfNameTemplateToSdwanNetworks < ActiveRecord::Migration[8.1]
  def change
    add_column :sdwan_networks, :vrf_name_template, :string,
               null: false, default: "sdwan-{handle}"
  end
end
