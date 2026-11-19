// Deferred fixture transport only. Build exact source consumer; no replacement evaluator.
import { createRequire } from 'node:module';
import { mkdirSync, copyFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
const [source, output] = process.argv.slice(2);
const require = createRequire(join(source, 'package.json'));
const vite = require.resolve('vite', { paths: [require.resolve('vitest/package.json')] });
const { build } = require(require.resolve('esbuild', { paths: [vite] }));
const relative = 'scripts/proposals/catalog-retained-selection';
mkdirSync(join(output, relative), { recursive: true });
mkdirSync(join(output, 'lib/catalog'), { recursive: true });
copyFileSync(join(source, 'lib/catalog/compareSpotifyDailyStreams.ts'), join(output, 'lib/catalog/compareSpotifyDailyStreams.ts'));
for (const name of ['readRetainedFieldSelection', 'consumeRetainedField', 'schemas']) {
  await build({ entryPoints: [join(source, relative, name + '.ts')], bundle: true,
    platform: 'node', format: 'esm', target: 'node20', outfile: join(output, relative, name + '.mjs') });
}
// Bundled evaluator keeps its new URL('./recipe.json', import.meta.url) lookup.
copyFileSync(join(source, 'scripts/proposals/catalog-stream-fields/recipe.json'), join(output, relative, 'recipe.json'));
writeFileSync(join(output, 'selection-driver.mjs'), `
import { readFileSync } from 'node:fs';
import { readRetainedFieldSelection } from './${relative}/readRetainedFieldSelection.mjs';
import { consumeRetainedField } from './${relative}/consumeRetainedField.mjs';
import { method } from './${relative}/schemas.mjs';
const input = JSON.parse(readFileSync(0, 'utf8'));
// Receipts/envelopes below come from the real disposable SQL harness, not a runtime route.
const selected = await readRetainedFieldSelection(input.scope, async () => input.receipt);
if (selected.state !== 'ready') console.log(JSON.stringify(selected));
else {
 const result = await consumeRetainedField(input.actor, {
  mode:'retained_field', workspaceId:input.scope.workspaceId, catalogId:input.scope.catalogId,
  field:'current_streams', query:input.query, method, selections:[selected.selection]
 }, async (_scope, consume) => consume({asOf:input.asOf,readBinding:async () => input.envelope}));
 console.log(JSON.stringify(result));
}
`);
