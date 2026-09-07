import { cp, mkdir, rm } from 'node:fs/promises';
await rm('dist', { recursive: true, force: true });
await mkdir('dist');
for (const file of ['index.html', 'style.css', 'src', 'favicon.svg']) await cp(file, `dist/${file}`, { recursive: true });
await cp('README.md', 'dist/README.md');
console.log('Built PiLyzer Web → dist/');
