import { myDevicesApi } from './myDevicesApi';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
  },
}));

// jsdom implements neither createObjectURL nor revokeObjectURL.
let createObjectURLMock: jest.Mock;
let revokeObjectURLMock: jest.Mock;
let clickSpy: jest.SpyInstance;
let createElementSpy: jest.SpyInstance;

beforeEach(() => {
  mockGet.mockReset();
  createObjectURLMock = jest.fn().mockReturnValue('blob:http://localhost/stub');
  revokeObjectURLMock = jest.fn();
  global.URL.createObjectURL = createObjectURLMock as unknown as typeof URL.createObjectURL;
  global.URL.revokeObjectURL = revokeObjectURLMock as unknown as typeof URL.revokeObjectURL;
  clickSpy = jest.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
  // Installed here rather than per-test: a spy restored inside the test body
  // leaks whenever an assertion above it fails, and the next `spyOn` then
  // wraps the leaked spy instead of the real method.
  createElementSpy = jest.spyOn(document, 'createElement');
});

afterEach(() => {
  clickSpy.mockRestore();
  createElementSpy.mockRestore();
  delete (global.URL as { createObjectURL?: unknown }).createObjectURL;
  delete (global.URL as { revokeObjectURL?: unknown }).revokeObjectURL;
});

/** Every anchor the code under test created, in creation order. */
const createdAnchors = (): HTMLAnchorElement[] =>
  createElementSpy.mock.results
    .map((r) => r.value as HTMLElement)
    .filter((el): el is HTMLAnchorElement => el instanceof HTMLAnchorElement);

// A SYNTHETIC stub, not a real config: the live body carries a WireGuard
// private key and nothing resembling one belongs in a fixture.
const STUB_CONFIG = '[Interface]\nPrivateKey = <stub>\n';

// =============================================================================
// listMyDevices
// =============================================================================

describe('myDevicesApi.listMyDevices', () => {
  it('GETs the top-level, un-nested my_devices path', async () => {
    mockGet.mockResolvedValue({ data: { success: true, data: { devices: [] } } });

    await myDevicesApi.listMyDevices();

    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/my_devices');
  });

  it('unwraps the envelope and returns the devices array with its derived fields', async () => {
    mockGet.mockResolvedValue({
      data: {
        success: true,
        data: {
          devices: [
            {
              id: 'dev-1',
              label: 'Laptop',
              status: 'pending_download',
              retrievable: true,
              network_id: 'net-1',
              created_at: '2026-08-01T00:00:00Z',
              last_downloaded_at: null,
            },
          ],
        },
      },
    });

    const devices = await myDevicesApi.listMyDevices();

    expect(devices).toHaveLength(1);
    expect(devices[0].status).toBe('pending_download');
    expect(devices[0].retrievable).toBe(true);
    expect(devices[0].last_downloaded_at).toBeNull();
  });

  it('returns an empty array when the payload omits devices', async () => {
    mockGet.mockResolvedValue({ data: { success: true, data: {} } });

    await expect(myDevicesApi.listMyDevices()).resolves.toEqual([]);
  });
});

// =============================================================================
// downloadMyDeviceConfig
// =============================================================================

describe('myDevicesApi.downloadMyDeviceConfig', () => {
  it('fetches the config THROUGH apiClient (which attaches the session JWT), not by navigating', async () => {
    mockGet.mockResolvedValue({ data: STUB_CONFIG });

    await myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop');

    // The only network call is the apiClient GET. apiClient is the axios
    // instance whose request interceptor sets `Authorization: Bearer <jwt>`;
    // a top-level navigation to the same URL would carry no such header and
    // the endpoint would answer 401.
    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/sdwan/my_devices/dev-1/config', {
      responseType: 'blob',
    });
  });

  it('never points an anchor at the API URL — the href is the local object URL', async () => {
    mockGet.mockResolvedValue({ data: STUB_CONFIG });

    await myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop');

    const anchors = createdAnchors();
    expect(anchors).toHaveLength(1);
    expect(anchors[0].getAttribute('href')).toBe('blob:http://localhost/stub');
    expect(anchors[0].getAttribute('href')).not.toContain('my_devices');

  });

  it('builds the file client-side from the response body and revokes the object URL', async () => {
    mockGet.mockResolvedValue({ data: STUB_CONFIG });

    await myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop');

    expect(createObjectURLMock).toHaveBeenCalledTimes(1);
    expect(createObjectURLMock.mock.calls[0][0]).toBeInstanceOf(Blob);
    expect(clickSpy).toHaveBeenCalledTimes(1);
  });

  it('revokes the object URL only AFTER the current task, so the save is not cut short', async () => {
    jest.useFakeTimers();
    try {
      mockGet.mockResolvedValue({ data: STUB_CONFIG });

      await myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop');

      // Still live at the moment the promise resolves: revoking inline (as
      // nodesApi does) produces an empty file in Safari/Firefox, and this is
      // the only delivery path a recipient has.
      expect(revokeObjectURLMock).not.toHaveBeenCalled();

      jest.runAllTimers();
      expect(revokeObjectURLMock).toHaveBeenCalledWith('blob:http://localhost/stub');
    } finally {
      jest.useRealTimers();
    }
  });

  it('passes a Blob response straight through instead of stringifying it', async () => {
    mockGet.mockResolvedValue({ data: new Blob([STUB_CONFIG], { type: 'text/plain' }) });

    await myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop');

    const blob = createObjectURLMock.mock.calls[0][0] as Blob;
    // `String(aBlob)` is "[object Blob]" (15 chars); the stub is longer, so
    // size alone discriminates the wrap-a-stringified-Blob bug.
    expect(blob.size).toBe(STUB_CONFIG.length);
  });

  it('names the file from a slugified label', async () => {
    mockGet.mockResolvedValue({ data: STUB_CONFIG });

    await myDevicesApi.downloadMyDeviceConfig('dev-1', "Everett's Laptop (work)");

    const anchor = createdAnchors()[0];
    expect(anchor.download).toBe('everett-s-laptop-work.conf');

  });

  it('does not leave a trailing separator when a long label is truncated', async () => {
    mockGet.mockResolvedValue({ data: STUB_CONFIG });

    // The 40-character cut lands exactly on a separator, so trimming only
    // BEFORE the slice would emit "...ccccc-.conf".
    await myDevicesApi.downloadMyDeviceConfig(
      'dev-1',
      'aaaaaaaaaa bbbbbbbbbb ccccccccccccccccc tail'
    );

    const anchor = createdAnchors()[0];
    expect(anchor.download).toBe('aaaaaaaaaa-bbbbbbbbbb-ccccccccccccccccc.conf');

  });

  it('falls back to the device id when the label slugifies to nothing', async () => {
    mockGet.mockResolvedValue({ data: STUB_CONFIG });

    await myDevicesApi.downloadMyDeviceConfig('abcdef0123456789', '///');

    const anchor = createdAnchors()[0];
    expect(anchor.download).toBe('device-abcdef01.conf');

  });

  it("surfaces the server's text/plain refusal text, and downloads nothing", async () => {
    // The 410 branch: the endpoint answers `# underlying access grant is not
    // active\n` as text/plain, delivered as a Blob because of responseType.
    mockGet.mockRejectedValue({
      response: {
        status: 410,
        data: new Blob(['# underlying access grant is not active\n'], { type: 'text/plain' }),
      },
    });

    await expect(myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop')).rejects.toThrow(
      'underlying access grant is not active'
    );
    expect(createObjectURLMock).not.toHaveBeenCalled();
    expect(clickSpy).not.toHaveBeenCalled();
  });

  it('falls back to the status code when the refusal body cannot be read', async () => {
    mockGet.mockRejectedValue({ response: { status: 503, data: undefined } });

    await expect(myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop')).rejects.toThrow(
      'Download failed (HTTP 503)'
    );
  });

  it('reports a transport failure that carries no response', async () => {
    mockGet.mockRejectedValue(new Error('Network Error'));

    await expect(myDevicesApi.downloadMyDeviceConfig('dev-1', 'Laptop')).rejects.toThrow(
      'Network Error'
    );
  });
});
