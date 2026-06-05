/**
 * Behavioral tests for architecturesApi.
 *
 * Covers every exported function: request shaping (URLs, payloads, query
 * params), response unwrapping via extractData, filter serialization, and
 * edge cases (null/undefined filters, empty collection fallback, void delete).
 */

import { architecturesApi } from './architecturesApi';
import type { ArchitectureCreate, ArchitectureListFilters } from './architecturesApi';
import type { SystemNodeArchitecture, ArchitectureFamily } from '../../types/system.types';

// =============================================================================
// Mocks
// =============================================================================

const mockGet = jest.fn();
const mockPost = jest.fn();
const mockPut = jest.fn();
const mockDelete = jest.fn();

jest.mock('@/shared/services/apiClient', () => ({
  apiClient: {
    get: (...args: unknown[]) => mockGet(...args),
    post: (...args: unknown[]) => mockPost(...args),
    put: (...args: unknown[]) => mockPut(...args),
    delete: (...args: unknown[]) => mockDelete(...args),
  },
}));

// =============================================================================
// Helpers & Fixtures
// =============================================================================

/** Wrap a payload in the double-envelope shape:
 *  AxiosResponse.data = { success: true, data: <payload> }
 */
function envelope<T>(payload: T) {
  return { data: { success: true, data: payload } };
}

function makeArch(overrides: Partial<SystemNodeArchitecture> = {}): SystemNodeArchitecture {
  return {
    id: 'arch-1',
    name: 'x86_64',
    family: 'x86' as ArchitectureFamily,
    enabled: true,
    public: true,
    is_canonical: true,
    created_at: '2026-01-01T00:00:00Z',
    updated_at: '2026-01-01T00:00:00Z',
    ...overrides,
  };
}

const ARCH_A = makeArch({ id: 'arch-a', name: 'x86_64', family: 'x86' });
const ARCH_B = makeArch({ id: 'arch-b', name: 'aarch64', family: 'arm', is_canonical: false });

// =============================================================================
// Tests
// =============================================================================

beforeEach(() => {
  mockGet.mockReset();
  mockPost.mockReset();
  mockPut.mockReset();
  mockDelete.mockReset();
});

// ---------------------------------------------------------------------------
// getArchitectures
// ---------------------------------------------------------------------------

describe('architecturesApi.getArchitectures', () => {
  it('calls GET /system/node_architectures with no params when called without filters', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_A, ARCH_B] })
    );

    const result = await architecturesApi.getArchitectures();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', { params: {} });
    expect(result).toEqual([ARCH_A, ARCH_B]);
  });

  it('calls GET /system/node_architectures with no params when called with undefined filters', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_A] })
    );

    await architecturesApi.getArchitectures(undefined);

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', { params: {} });
  });

  it('serializes family filter into query params', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_A] })
    );

    const filters: ArchitectureListFilters = { family: 'x86' };
    await architecturesApi.getArchitectures(filters);

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { family: 'x86' },
    });
  });

  it('serializes is_canonical=true as string "true"', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_A] })
    );

    await architecturesApi.getArchitectures({ is_canonical: true });

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { is_canonical: 'true' },
    });
  });

  it('serializes is_canonical=false as string "false"', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_B] })
    );

    await architecturesApi.getArchitectures({ is_canonical: false });

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { is_canonical: 'false' },
    });
  });

  it('serializes enabled=true as string "true"', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_A] })
    );

    await architecturesApi.getArchitectures({ enabled: true });

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { enabled: 'true' },
    });
  });

  it('serializes enabled=false as string "false"', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [] })
    );

    await architecturesApi.getArchitectures({ enabled: false });

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { enabled: 'false' },
    });
  });

  it('serializes all three filters together', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [ARCH_A] })
    );

    const filters: ArchitectureListFilters = {
      family: 'arm',
      is_canonical: true,
      enabled: true,
    };
    await architecturesApi.getArchitectures(filters);

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { family: 'arm', is_canonical: 'true', enabled: 'true' },
    });
  });

  it('does NOT include is_canonical or enabled when they are undefined', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [] })
    );

    // Explicitly passing an object with undefined values — they must be omitted
    await architecturesApi.getArchitectures({ family: 'power', is_canonical: undefined, enabled: undefined });

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures', {
      params: { family: 'power' },
    });
  });

  it('returns an empty array when node_architectures is absent from the response', async () => {
    // Backend omits the key — fallback to []
    mockGet.mockResolvedValueOnce(
      envelope({} as { node_architectures: SystemNodeArchitecture[] })
    );

    const result = await architecturesApi.getArchitectures();

    expect(result).toEqual([]);
  });

  it('returns an empty array when node_architectures is an empty list', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [] })
    );

    const result = await architecturesApi.getArchitectures();

    expect(result).toEqual([]);
  });

  it('unwraps the full architecture objects returned by the backend', async () => {
    const arch = makeArch({
      id: 'full-1',
      name: 'riscv64',
      family: 'risc-v',
      apt_name: 'riscv64',
      rpm_name: 'riscv64',
      display_name: 'RISC-V 64-bit',
      description: 'Open ISA RISC-V',
      kernel_options: 'earlycon',
      aliases: ['riscv', 'riscv64gc'],
      is_canonical: false,
    });

    mockGet.mockResolvedValueOnce(
      envelope({ node_architectures: [arch] })
    );

    const result = await architecturesApi.getArchitectures();

    expect(result).toHaveLength(1);
    expect(result[0]).toEqual(arch);
  });
});

// ---------------------------------------------------------------------------
// getArchitecture
// ---------------------------------------------------------------------------

describe('architecturesApi.getArchitecture', () => {
  it('calls GET /system/node_architectures/:id', async () => {
    mockGet.mockResolvedValueOnce(
      envelope({ node_architecture: ARCH_A })
    );

    const result = await architecturesApi.getArchitecture('arch-a');

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures/arch-a');
    expect(result).toEqual(ARCH_A);
  });

  it('interpolates arbitrary IDs correctly', async () => {
    const arch = makeArch({ id: 'some-uuid-1234' });
    mockGet.mockResolvedValueOnce(
      envelope({ node_architecture: arch })
    );

    const result = await architecturesApi.getArchitecture('some-uuid-1234');

    expect(mockGet).toHaveBeenCalledWith('/system/node_architectures/some-uuid-1234');
    expect(result).toEqual(arch);
  });

  it('unwraps the node_architecture field from the envelope', async () => {
    const arch = makeArch({ id: 'arch-b', name: 'aarch64', family: 'arm' });
    mockGet.mockResolvedValueOnce(
      envelope({ node_architecture: arch })
    );

    const result = await architecturesApi.getArchitecture('arch-b');

    expect(result.id).toBe('arch-b');
    expect(result.name).toBe('aarch64');
    expect(result.family).toBe('arm');
  });
});

// ---------------------------------------------------------------------------
// createArchitecture
// ---------------------------------------------------------------------------

describe('architecturesApi.createArchitecture', () => {
  it('calls POST /system/node_architectures with the correct body wrapper', async () => {
    const created = makeArch({ id: 'new-arch', name: 'new_x86', family: 'x86' });
    mockPost.mockResolvedValueOnce(
      envelope({ node_architecture: created })
    );

    const payload: ArchitectureCreate = {
      name: 'new_x86',
      family: 'x86',
    };

    const result = await architecturesApi.createArchitecture(payload);

    expect(mockPost).toHaveBeenCalledTimes(1);
    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_architectures',
      { node_architecture: payload }
    );
    expect(result).toEqual(created);
  });

  it('wraps the full optional payload inside node_architecture key', async () => {
    const fullPayload: ArchitectureCreate = {
      name: 'mips32',
      family: 'mips',
      apt_name: 'mipsel',
      rpm_name: 'mips',
      display_name: 'MIPS 32-bit',
      description: 'Legacy MIPS architecture',
      kernel_options: 'console=ttyS0',
      aliases: ['mipsel', 'mips32'],
      enabled: true,
      public: false,
    };

    const created = makeArch({ id: 'mips-arch', ...fullPayload });
    mockPost.mockResolvedValueOnce(
      envelope({ node_architecture: created })
    );

    await architecturesApi.createArchitecture(fullPayload);

    expect(mockPost).toHaveBeenCalledWith(
      '/system/node_architectures',
      { node_architecture: fullPayload }
    );
  });

  it('returns the unwrapped created architecture', async () => {
    const created = makeArch({ id: 'created-id', name: 'z_arch', family: 'z' });
    mockPost.mockResolvedValueOnce(
      envelope({ node_architecture: created })
    );

    const result = await architecturesApi.createArchitecture({ name: 'z_arch', family: 'z' });

    expect(result.id).toBe('created-id');
    expect(result.name).toBe('z_arch');
    expect(result.family).toBe('z');
  });
});

// ---------------------------------------------------------------------------
// updateArchitecture
// ---------------------------------------------------------------------------

describe('architecturesApi.updateArchitecture', () => {
  it('calls PUT /system/node_architectures/:id with the partial data wrapped', async () => {
    const updated = makeArch({ id: 'arch-a', name: 'updated_x86', family: 'x86' });
    mockPut.mockResolvedValueOnce(
      envelope({ node_architecture: updated })
    );

    const patch: Partial<ArchitectureCreate> = { name: 'updated_x86', enabled: false };

    const result = await architecturesApi.updateArchitecture('arch-a', patch);

    expect(mockPut).toHaveBeenCalledTimes(1);
    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_architectures/arch-a',
      { node_architecture: patch }
    );
    expect(result).toEqual(updated);
  });

  it('interpolates the id into the URL', async () => {
    const updated = makeArch({ id: 'target-uuid' });
    mockPut.mockResolvedValueOnce(
      envelope({ node_architecture: updated })
    );

    await architecturesApi.updateArchitecture('target-uuid', { description: 'Updated' });

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_architectures/target-uuid',
      { node_architecture: { description: 'Updated' } }
    );
  });

  it('accepts an empty patch object (no fields to update)', async () => {
    const arch = makeArch({ id: 'arch-a' });
    mockPut.mockResolvedValueOnce(
      envelope({ node_architecture: arch })
    );

    const result = await architecturesApi.updateArchitecture('arch-a', {});

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_architectures/arch-a',
      { node_architecture: {} }
    );
    expect(result).toEqual(arch);
  });

  it('accepts aliases update and wraps it correctly', async () => {
    const arch = makeArch({ id: 'arch-b', aliases: ['arm64', 'ARMv8'] });
    mockPut.mockResolvedValueOnce(
      envelope({ node_architecture: arch })
    );

    await architecturesApi.updateArchitecture('arch-b', { aliases: ['arm64', 'ARMv8'] });

    expect(mockPut).toHaveBeenCalledWith(
      '/system/node_architectures/arch-b',
      { node_architecture: { aliases: ['arm64', 'ARMv8'] } }
    );
  });

  it('returns the unwrapped updated architecture', async () => {
    const updated = makeArch({ id: 'arch-a', enabled: false });
    mockPut.mockResolvedValueOnce(
      envelope({ node_architecture: updated })
    );

    const result = await architecturesApi.updateArchitecture('arch-a', { enabled: false });

    expect(result.enabled).toBe(false);
    expect(result.id).toBe('arch-a');
  });
});

// ---------------------------------------------------------------------------
// deleteArchitecture
// ---------------------------------------------------------------------------

describe('architecturesApi.deleteArchitecture', () => {
  it('calls DELETE /system/node_architectures/:id', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await architecturesApi.deleteArchitecture('arch-a');

    expect(mockDelete).toHaveBeenCalledTimes(1);
    expect(mockDelete).toHaveBeenCalledWith('/system/node_architectures/arch-a');
  });

  it('interpolates arbitrary IDs into the delete URL', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    await architecturesApi.deleteArchitecture('some-other-uuid');

    expect(mockDelete).toHaveBeenCalledWith('/system/node_architectures/some-other-uuid');
  });

  it('resolves to void (returns undefined)', async () => {
    mockDelete.mockResolvedValueOnce({ data: { success: true } });

    const result = await architecturesApi.deleteArchitecture('arch-a');

    expect(result).toBeUndefined();
  });
});
