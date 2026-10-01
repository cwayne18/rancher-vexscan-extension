import { STATE, NAME as NAME_COL, AGE } from '@shell/config/table-headers';
import { PRODUCT_NAME, SCAN_REPORT, OVERVIEW_PAGE } from './config/constants';

// vexscan is cluster-scoped: it reports on the RKE2 build actually running
// in *this* downstream cluster, so it lives under a cluster's nav (inStore:
// 'cluster'), not the global "_" blank-cluster product used by Fleet/Cluster
// Management style extensions.
export function init($plugin: any, store: any) {
  const {
    product, configureType, virtualType, basicType, headers,
  } = $plugin.DSL(store, PRODUCT_NAME);

  product({
    // Only show the nav entry in clusters where the vexscan-scanner chart's
    // CRD is actually installed (same gating pattern rancher-gatekeeper uses
    // for its own CRD group), so vexscan doesn't clutter clusters that
    // haven't opted in yet.
    ifHaveGroup: /^(.*\.)?vexscan\.cattle\.io$/,
    icon:        'gear',
    inStore:     'cluster',
    weight:      -3, // just under the built-in "Cluster" explorer entries
    to:          {
      name:   `${ PRODUCT_NAME }-c-cluster-${ OVERVIEW_PAGE }`,
      params: { product: PRODUCT_NAME },
    },
  });

  virtualType({
    labelKey: 'vexscan.nav.overview',
    name:     OVERVIEW_PAGE,
    weight:   10,
    route:    {
      name:   `${ PRODUCT_NAME }-c-cluster-${ OVERVIEW_PAGE }`,
      params: { product: PRODUCT_NAME },
    },
  });

  // The CRD itself (vexscan.cattle.io.scanreport) is also browsable like any
  // other k8s resource, for anyone who wants raw/yaml access or to script
  // against it rather than use the Overview dashboard.
  configureType(SCAN_REPORT, {
    displayName: 'Scan Report',
    isCreatable: false,
    isEditable:  false,
    isRemovable: true,
    showAge:     true,
    showState:   true,
    canYaml:     true,
  });

  headers(SCAN_REPORT, [
    STATE,
    NAME_COL,
    {
      name:     'rke2Version',
      label:    'RKE2 Version',
      getValue: (row: any) => row.spec?.rke2Version,
      sort:     'spec.rke2Version',
      search:   'spec.rke2Version',
    },
    {
      name:     'critical',
      label:    'Critical',
      getValue: (row: any) => row.status?.summary?.critical ?? 0,
    },
    {
      name:     'high',
      label:    'High',
      getValue: (row: any) => row.status?.summary?.high ?? 0,
    },
    {
      name:     'affected',
      label:    'Affected',
      getValue: (row: any) => row.status?.summary?.affected ?? 0,
    },
    AGE,
  ]);

  basicType([OVERVIEW_PAGE, SCAN_REPORT]);
}
