// Bundle the generated browser module. Paths resolve from the viewer directory.
import { mkdir, copyFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export const viewerRoot = fileURLToPath(new URL('../', import.meta.url));
export async function buildViewer() {
  const dist = resolve(viewerRoot, 'web/dist');
  await mkdir(dist, { recursive: true });
  const result = await build({
    absWorkingDir: viewerRoot,
    entryPoints: ['web/main.mjs'],
    outfile: 'web/dist/app.js',
    bundle: true,
    format: 'esm',
    platform: 'browser',
    target: ['es2022'],
    sourcemap: true,
    define: { 'process.env.NODE_ENV': '"development"' },
    logLevel: 'info',
  });
  await copyFile(resolve(viewerRoot, 'web/index.html'), resolve(dist, 'index.html'));
  await copyFile(resolve(viewerRoot, 'web/style.css'), resolve(dist, 'style.css'));
  await copyFile(resolve(viewerRoot, 'vendor/assistant-ui/thread.css'), resolve(dist, 'thread.css'));
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await buildViewer(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
