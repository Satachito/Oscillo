import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
await rm('dist', { recursive: true, force: true });
await mkdir('dist');
for (const file of ['index.html', 'style.css', 'src', 'favicon.svg']) await cp(file, `dist/${file}`, { recursive: true });
await cp('README.md', 'dist/README.md');
// The version in the footer is package.json's, which is the Mac
// application's too (Scripts/make-app.sh): one number for a release.
const { version } = JSON.parse(await readFile('package.json', 'utf8'));
const page = await readFile('dist/index.html', 'utf8');
await writeFile('dist/index.html', page.replace(/(PiLyzer Web <span>)v[^<]*(<\/span>)/, `$1v${version}$2`));
console.log('Built PiLyzer Web → dist/');
