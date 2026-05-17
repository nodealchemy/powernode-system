// Package federation implements the agent's first-run federation
// handshake — the work that completes a spawn flow from the child
// side after the agent has enrolled with the platform's local CA.
//
// The parent's SpawnPlatformService injected the spawn payload via
// virtio-fw-cfg (per CloudSeed):
//
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/parent_url
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/acceptance_token
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/spawn_mode
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/parent_peer_id
//	/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/contract_version
//
// On first run, the agent reads these keys, then POSTs the
// acceptance_token to <parent_url>/api/v1/system/federation_api/accept.
// On success it writes a local marker file so subsequent agent boots
// skip the handshake — the bootstrap token is single-use and the
// peer row transitions out of `proposed` after one accept.
//
// Plan reference: Decentralized Federation §H + P6.5.
package federation
