// Phase B.4 — SDWAN hub tab orchestrators.
// Note: the Routing tab uses SdwanRoutingPage directly with embedded={true}
// (refactored to support skipping its own PageContainer). It's not in
// this barrel because it lives at pages/app/system/SdwanRoutingPage.tsx
// to keep its standalone route working too.
export { NetworksTab } from './NetworksTab';
export { FederationTab } from './FederationTab';
