// Test-only transport: compile the pinned actual evaluator, never a replacement.
import { createRequire } from 'node:module';
import { mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [source, output] = process.argv.slice(2);
const require = createRequire(join(source, 'package.json'));
const vite = require.resolve('vite', { paths: [require.resolve('vitest/package.json')] });
const { build } = require(require.resolve('esbuild', { paths: [vite] }));
const relative = 'scripts/proposals/catalog-stream-fields';
mkdirSync(join(output, relative), { recursive: true });
mkdirSync(join(output, 'lib/catalog'), { recursive: true });
await build({ entryPoints: [join(source, relative, 'evaluate.ts')], bundle: true,
  platform: 'node', format: 'esm', target: 'node20', outfile: join(output, relative, 'evaluate.mjs') });
copyFileSync(join(source, relative, 'recipe.json'), join(output, relative, 'recipe.json'));
copyFileSync(join(source, 'lib/catalog/compareSpotifyDailyStreams.ts'), join(output, 'lib/catalog/compareSpotifyDailyStreams.ts'));
writeFileSync(join(output, 'driver.mjs'), `import { evaluateRetainedStreamField } from './${relative}/evaluate.mjs';
import { readFileSync } from 'node:fs';
console.log(JSON.stringify(evaluateRetainedStreamField(JSON.parse(readFileSync(0, 'utf8')))));\n`);
