/**
 * System Feature Module — barrel export.
 *
 * Previously re-exported status / audit-logs / storage / workers feature
 * modules; those were moved to the platform's admin/* surface, leaving
 * this barrel empty. Direct imports from `@system/features/system/<area>/...`
 * are still the convention for the surfaces that remain (modules, nodes,
 * fleet, providers, templates, etc.).
 */
export {};
