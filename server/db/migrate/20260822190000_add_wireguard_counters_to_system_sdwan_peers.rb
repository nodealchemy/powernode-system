# frozen_string_literal: true

# IMP-ab73cc2fca65 — land the per-peer WireGuard byte counters the agent has
# been measuring and shipping all along.
#
# agent/internal/sdwan/wg_applier.go#ReadActualState parses fields 5 and 6 of
# `wg show <if> dump` into ActualPeerState.{Rx,Tx}Bytes; manager.go carries them
# into PeerStatusReport (`json:"rx_bytes"` / `"tx_bytes"`, no omitempty) on every
# heartbeat POST to /node_api/status/sdwan. The controller persisted only
# last_handshake_at, so the counters were parsed, transmitted, and dropped.
#
# NOT MEASURED vs MEASURED-ZERO (the whole reason these are nullable):
# an idle peer legitimately reports rx_bytes: 0, so "no sample" and "sampled,
# zero traffic" are DIFFERENT facts and must stay distinguishable. NULL is the
# absence signal — the same rule the agent's per-subsystem outcome map uses
# (28460bbb: "absence is the NOT MEASURED signal"). Nothing writes a zero
# default, and no backfill runs: every existing peer starts NOT MEASURED and
# becomes measured only when a heartbeat carries a usable counter pair.
#
# RAW CUMULATIVE, NOT DELTAS. These hold exactly what the kernel reported —
# WireGuard's per-peer lifetime totals for the CURRENT interface incarnation.
# Those totals restart at zero when the interface is recreated or the peer is
# re-added, so a sample may legitimately be LOWER than the one before it. The
# platform therefore never clamps, never rejects a decrease, and never
# differences: a monotonic guard would freeze the counter after the first
# reconnect, and a stored delta would have to guess whether a drop was a reset
# or a rollback. Deltas are the reader's problem, and counters_sampled_at is
# what makes them computable: a reader holding two (value, sampled_at) pairs
# treats `newer_value < older_value` as a reset and takes newer_value itself as
# the interval's traffic.
#
# counters_sampled_at is also the only freshness signal available, because the
# write is an update_columns that deliberately does NOT touch updated_at — the
# same choice the existing last_handshake_at write already makes. A heartbeat
# is an observation, not an edit: bumping updated_at once a minute for every
# peer in the fleet would destroy it as a "when was this peer last changed"
# signal and would fire the model's after_save hooks on every tick. So the
# observation needs a stamp of its own, and this is it.
class AddWireguardCountersToSystemSdwanPeers < ActiveRecord::Migration[8.0]
  def change
    # bigint: WireGuard counters are uint64 kernel-side and the agent carries
    # them as int64. A 4-byte integer overflows at 2 GiB on a link that moves
    # that in minutes.
    add_column :system_sdwan_peers, :rx_bytes, :bigint
    add_column :system_sdwan_peers, :tx_bytes, :bigint
    add_column :system_sdwan_peers, :counters_sampled_at, :datetime
  end
end
