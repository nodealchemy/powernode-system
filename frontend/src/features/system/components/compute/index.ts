// Phase B.1 — Compute hub tab orchestrators.
// Each tab strips its standalone PageContainer and exposes an
// onActionsReady callback so the parent ComputePage hub can wire
// per-tab actions into its top-level PageContainer.actions.
export { NodesTab } from './NodesTab';
export { UnclaimedDevicesTab } from './UnclaimedDevicesTab';
export { VolumesTab } from './VolumesTab';
export { ProvidersTab } from './ProvidersTab';
export { NetworksTab } from './NetworksTab';
