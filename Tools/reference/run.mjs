// Runs upstream defuddle (node build) on an HTML file and prints the comparable result.
// usage: node run.mjs <defuddle-dir> <file.html> <url> [--html]
import { readFileSync } from 'fs';
import { pathToFileURL } from 'url';
const [dir, file, url, flag] = process.argv.slice(2);
const { Defuddle } = await import(pathToFileURL(`${dir}/dist/node.js`).href);
const { parseLinkedomHTML } = await import(pathToFileURL(`${dir}/dist/utils/linkedom-compat.js`).href);
const html = readFileSync(file, 'utf-8');
const doc = parseLinkedomHTML(html, url);
const offline = () => Promise.reject(new Error('offline'));
const r = await Defuddle(doc, url, { separateMarkdown: true, fetch: offline });
if (flag === '--html') { console.log(r.content); process.exit(0); }
const meta = { title: r.title, author: r.author, site: r.site, published: r.published };
process.stdout.write('```json\n' + JSON.stringify(meta, null, 2) + '\n```\n\n' + r.contentMarkdown);
