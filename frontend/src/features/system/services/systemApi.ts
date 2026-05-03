// systemApi — unified façade over per-domain API modules.
//
// The 11 domain modules under ./api/ each own their HTTP surface and types.
// This file is a thin aggregator that spreads them into a single object so
// existing call sites keep working: `systemApi.getNodes(...)`,
// `systemApi.createTask(...)`, etc.
//
// Consumers that prefer narrower typing can import a domain module directly:
//
//   import { tasksApi } from '@system/features/system/services/api/tasksApi';
//   tasksApi.getTasks();
//
// Per-domain imports surface only the types each domain uses, which is
// considerably tighter than the kitchen-sink `systemApi` shape.
import { overviewApi } from './api/overviewApi';
import { nodesApi } from './api/nodesApi';
import { templatesApi } from './api/templatesApi';
import { platformsApi } from './api/platformsApi';
import { architecturesApi } from './api/architecturesApi';
import { scriptsApi } from './api/scriptsApi';
import { providersApi } from './api/providersApi';
import { modulesApi } from './api/modulesApi';
import { tasksApi } from './api/tasksApi';
import { puppetApi } from './api/puppetApi';
import { volumesApi } from './api/volumesApi';
import { networksApi } from './api/networksApi';
import { unclaimedDevicesApi } from './api/unclaimedDevicesApi';

// Re-export domain modules for callers that want narrower typing.
export {
  overviewApi,
  nodesApi,
  templatesApi,
  platformsApi,
  architecturesApi,
  scriptsApi,
  providersApi,
  modulesApi,
  tasksApi,
  puppetApi,
  volumesApi,
  networksApi,
  unclaimedDevicesApi,
};

export const systemApi = {
  ...overviewApi,
  ...nodesApi,
  ...templatesApi,
  ...platformsApi,
  ...architecturesApi,
  ...scriptsApi,
  ...providersApi,
  ...modulesApi,
  ...tasksApi,
  ...puppetApi,
  ...volumesApi,
  ...networksApi,
};
