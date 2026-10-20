import { cp, mkdir, rm, access } from 'node:fs/promises';
await access('../doer/build/web/index.html');
await rm('dist', { recursive: true, force: true });
await mkdir('dist/app', { recursive: true });
await cp('landing', 'dist', { recursive: true });
await cp('../doer/build/web', 'dist/app', { recursive: true });
