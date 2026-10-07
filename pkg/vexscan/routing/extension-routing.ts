import ListResource from '@shell/pages/c/_cluster/_product/_resource/index.vue';
import ViewResource from '@shell/pages/c/_cluster/_product/_resource/_id.vue';
import Overview from '../pages/overview.vue';
import { PRODUCT_NAME, OVERVIEW_PAGE } from '../config/constants';

const routes = [
  {
    name:      `${ PRODUCT_NAME }-c-cluster-${ OVERVIEW_PAGE }`,
    path:      `/${ PRODUCT_NAME }/c/:cluster/${ OVERVIEW_PAGE }`,
    component: Overview,
    meta:      { product: PRODUCT_NAME },
  },
  // Generic CRD list/detail, reused from the shell so vexscan.cattle.io.vexscanreport
  // gets YAML view, events and conditions for free.
  {
    name:      `${ PRODUCT_NAME }-c-cluster-resource`,
    path:      `/${ PRODUCT_NAME }/c/:cluster/:resource`,
    component: ListResource,
    meta:      { product: PRODUCT_NAME },
  },
  {
    name:      `${ PRODUCT_NAME }-c-cluster-resource-id`,
    path:      `/${ PRODUCT_NAME }/c/:cluster/:resource/:id`,
    component: ViewResource,
    meta:      { product: PRODUCT_NAME },
  },
];

export default routes;
