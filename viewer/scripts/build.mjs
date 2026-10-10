// The browser bundle (CONTRACT.md, "Browser"). Paths resolve from this file, not the cwd, so
// `node scripts/build.mjs` works from anywhere. The viewer has no node_modules of its own: it
// links the LeanReact checkout's, so react, react-dom, @assistant-ui/react, esbuild and jsdom
// resolve from the viewer directory as well as from the adapters the generated module imports.
import { mkdir, copyFile, symlink, lstat } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve, relative } from 'node:path';

export const viewerRoot = fileURLToPath(new URL('../', import.meta.url));
export const leanreactRoot = resolve(viewerRoot, '../../leanreact');
const nodeModules = resolve(leanreactRoot, 'node_modules');

/** `viewer/node_modules -> ../../leanreact/node_modules` (relative, so the checkouts can move together). */
export async function linkNodeModules() {
  const link = resolve(viewerRoot, 'node_modules');
  try { await lstat(link); return link; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  await symlink(relative(viewerRoot, nodeModules), link, 'dir');
  return link;
}

export async function buildViewer() {
  await linkNodeModules();
  // esbuild from the LeanReact checkout, resolved the way Node would from there.
  const require = createRequire(pathToFileURL(resolve(leanreactRoot, 'package.json')));
  const { build } = await import(pathToFileURL(require.resolve('esbuild')).href);
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
    nodePaths: [nodeModules],
    define: { 'process.env.NODE_ENV': '"development"' },
    logLevel: 'info',
  });
  await copyFile(resolve(viewerRoot, 'web/index.html'), resolve(dist, 'index.html'));
  await copyFile(resolve(viewerRoot, 'web/style.css'), resolve(dist, 'style.css'));
  await copyFile(resolve(leanreactRoot, 'adapters/assistant-ui/thread.css'), resolve(dist, 'thread.css'));
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await buildViewer(); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
