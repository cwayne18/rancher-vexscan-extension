<script>
// SortableTable cell formatter registered as 'ConfigMapLink' via the
// `formatters/` auto-import convention (@rancher/shell/pkg/auto-import.js -
// the file name, minus extension, becomes the formatter name resolved by
// $extension.getDynamic('formatters', name)). Renders a link to the core
// Explorer ConfigMap detail view for the gzipped vexscan report named by
// `value` (a ComponentResult's reportConfigMapRef - see
// scanner/entrypoint.sh and models/vexscan.cattle.io.vexscanreport.ts).
//
// The ConfigMap holds a single `report.json.gz` key. Large reports may have
// had per-finding evidence chains stripped, or been capped to the top N
// findings per status bucket, to fit the 1MiB ConfigMap size limit - no
// bucket is ever fully dropped (see status.message for whether/how this
// report was degraded).
import { CONFIG_MAP } from '@shell/config/types';
import LinkName from '@shell/components/formatter/LinkName.vue';

// Fixed by the chart's values.yaml `namespace` default and the scanner's own
// namespaced Role (see charts/vexscan-scanner/templates/role.yaml), which
// only ever writes ConfigMaps into this one namespace.
const NAMESPACE = 'cattle-vexscan-system';

export default {
  components: { LinkName },

  props: {
    value: {
      type:    String,
      default: '',
    },
  },

  data() {
    return { CONFIG_MAP, NAMESPACE };
  },
};
</script>

<template>
  <LinkName
    v-if="value"
    :type="CONFIG_MAP"
    :namespace="NAMESPACE"
    :object-id="value"
    :value="value"
  />
  <span v-else>&mdash;</span>
</template>
