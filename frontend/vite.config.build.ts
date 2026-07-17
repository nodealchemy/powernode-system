import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import svgr from 'vite-plugin-svgr';
import path from 'path';
import fs from 'fs';
import { HOST_EXPOSED_IDS, CORE_UI_API_VERSION } from '../../../frontend/src/shared/host-api/modules';

/**
 * Dedicated-module build (Phase 2) for the system extension's frontend.
 *
 * Produces a standalone ESM bundle for `src/register.ts` that core loads at
 * RUNTIME (see `frontend/src/shared/services/extensionLoader.ts`'s
 * `loadRuntimeExtensions`), instead of the "eager glob" path that bakes
 * `register.ts` into core's OWN main bundle (`extensionLoader.ts`'s
 * `import.meta.glob(..., { eager: true })`) — that path is unaffected by
 * this file; it's used by core's monolithic build, this one by the composed
 * fleet-instance build (`stage15.sh`'s `powernode-extension-system` arm).
 *
 * THE ONE THING THIS FILE MUST GET RIGHT: every id in `HOST_EXPOSED_IDS`
 * (core's `@/…` modules + the npm singletons — react, redux, etc.) must
 * come out the other end as an unresolved bare `import … from '<id>'` in the
 * emitted JS, NOT inlined. `external` alone accomplishes this — critically,
 * this config defines NO alias/resolver for any of those ids (no
 * `vite-tsconfig-paths`, no `@` alias), so nothing ever resolves them to a
 * real file first. If a resolver ran first and handed Rollup back an
 * absolute path, the (string-array) `external` check — which matches
 * against the literal, as-written import id — would silently stop matching
 * and the module would get bundled in by mistake. Verified empirically:
 * `npx vite build --config vite.config.build.ts`, then grep the output for
 * `from "react"` / `from "@/shared/services/apiClient"` (present, bare) vs.
 * `from "lucide-react"` (absent — inlined, since it's NOT in
 * HOST_EXPOSED_IDS and must ship with the extension).
 */
const distDir = path.resolve(__dirname, 'dist');

/**
 * Writes `dist/manifest.json` — the contract `extensionLoader.ts` fetches at
 * `/extensions/system/manifest.json` before dynamically importing the entry.
 * Runs in `generateBundle` (not `writeBundle`) so it can `this.emitFile` the
 * manifest into the SAME output write as the hashed entry/css, using the
 * bundle's actual emitted filenames (never guessed/reconstructed).
 */
function extensionManifestPlugin(): Plugin {
  return {
    name: 'system-extension-manifest',
    generateBundle(_options, bundle) {
      const extensionJson = JSON.parse(
        fs.readFileSync(path.resolve(__dirname, '../extension.json'), 'utf-8'),
      ) as { slug: string; version: string };

      let entry: string | undefined;
      const css: string[] = [];
      for (const output of Object.values(bundle)) {
        if (output.type === 'chunk' && output.isEntry && output.name === 'register') {
          entry = output.fileName;
        } else if (output.type === 'asset' && output.fileName.endsWith('.css')) {
          css.push(output.fileName);
        }
      }
      if (!entry) {
        this.error('[system-extension-manifest] no "register" entry chunk found in bundle');
      }

      this.emitFile({
        type: 'asset',
        fileName: 'manifest.json',
        source: JSON.stringify(
          {
            slug: extensionJson.slug,
            version: extensionJson.version,
            coreUiApi: CORE_UI_API_VERSION,
            entry,
            css,
          },
          null,
          2,
        ),
      });
    },
  };
}

export default defineConfig({
  // No `root` override: stays `extensions/system/frontend` (this file's own
  // directory), matching where `src/register.ts` and the symlinked
  // `node_modules` (→ ../../../frontend/node_modules; see
  // scripts/setup-extension-frontend-symlinks.sh) both live.
  plugins: [
    react(),
    svgr({ svgrOptions: { icon: true } }),
    extensionManifestPlugin(),
  ],

  resolve: {
    alias: {
      // Intra-extension imports only (e.g. `@system/features/...` — see
      // register.test.ts's own relative import for how sparse these are).
      // Deliberately NOT aliasing `@/…` — see the file-header comment.
      '@system': path.resolve(__dirname, './src'),
    },
  },

  css: {
    // This build's `root` has no ancestor `postcss.config.js` of its own
    // (that file lives in `frontend/`, a SIBLING of `extensions/`, not an
    // ancestor of `extensions/system/frontend/`) — point postcss-load-config
    // at core's directory explicitly so `ext.css`'s `@import "tailwindcss/…"`
    // runs through the SAME `@tailwindcss/postcss` + `autoprefixer` pipeline
    // core's own build uses (see `frontend/postcss.config.js`).
    postcss: path.resolve(__dirname, '../../../frontend'),
  },

  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // Sourcemaps are useful here too (core's own build enables them) and cost
    // nothing at runtime (browsers only fetch them on request).
    sourcemap: true,
    rollupOptions: {
      // CRITICAL: Vite defaults preserveEntrySignatures to `false` for
      // app-style builds (rollupOptions.input), which tree-shakes the entry's
      // exports as "unused" — that dropped register()'s entire body (the
      // featureRegistry.register* calls), leaving only bare side-effect imports
      // and NO menu registration. Preserve the register export so the extension
      // actually registers its routes/nav on import().
      preserveEntrySignatures: 'strict',
      input: {
        register: path.resolve(__dirname, 'src/register.ts'),
        style: path.resolve(__dirname, 'src/ext.css'),
      },
      // The coupling contract with core (see modules.ts's own header) —
      // every one of these MUST come out as a bare, unresolved import.
      external: [...HOST_EXPOSED_IDS],
      output: {
        format: 'es',
        dir: distDir,
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash][extname]',
      },
    },
  },
});
