// Which typed FleetEvent column carries each component kind's id — the one
// place the component drawer's per-component signals view learns it.
//
// POST /system/fleet/signals filters by these columns, never by payload keys
// (design §6, signals ruling). Every kind here has `ref_for(record) =
// record.id` in its status contributor, so the drawer row's component_ref IS
// the value the column holds. register.ts derives one
// `platform.status.drawer.<kind>.signals` slot per key, so adding a kind here
// is the whole registration.
export const SIGNAL_FILTER_COLUMN_BY_KIND = {
  node_instance: 'node_instance_id',
  node_module: 'node_module_id',
  acme_certificate: 'certificate_id',
} as const;

export type SignalsKind = keyof typeof SIGNAL_FILTER_COLUMN_BY_KIND;
export type SignalFilterColumn = (typeof SIGNAL_FILTER_COLUMN_BY_KIND)[SignalsKind];

export const isSignalsKind = (kind: string): kind is SignalsKind =>
  Object.prototype.hasOwnProperty.call(SIGNAL_FILTER_COLUMN_BY_KIND, kind);
