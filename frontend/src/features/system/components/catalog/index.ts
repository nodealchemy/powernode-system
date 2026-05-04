// Phase B.2 — Catalog hub tab orchestrators.
// Each tab strips its standalone PageContainer and exposes an
// onActionsReady callback so CatalogPage can wire per-tab actions
// into its top-level PageContainer.actions.
export { TemplatesTab } from './TemplatesTab';
export { ModulesTab } from './ModulesTab';
export { PuppetModulesTab } from './PuppetModulesTab';
export { ScriptsTab } from './ScriptsTab';
export { ArchitecturesTab } from './ArchitecturesTab';
export { PlatformsTab } from './PlatformsTab';
export { MarketplaceTab } from './MarketplaceTab';
