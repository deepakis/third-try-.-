// Verify the SHA-256 / OBS auth code that lives inside public/index.html,
// by extracting it from the file and comparing against node:crypto.
// Run:  node tools/verify_page_auth.mjs

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const html = readFileSync('public/index.html', 'utf8');

// Pull the exact source of the JS helpers out of the page.
const grab = (start, end) => {
  const i = html.indexOf(start);
  const j = html.indexOf(end, i);
  if (i < 0 || j < 0) throw new Error(`could not extract ${start}`);
  return html.slice(i, j);
};
const source =
  grab('const K = new Uint32Array(', '/* ---------------------------------- UI') ;

const b64bytes = (bytes) => Buffer.from(bytes).toString('base64');
const factory = new Function('btoa', `${source}\nreturn { sha256Bytes, sha256b64, obsAuth };`);
const { sha256b64, obsAuth } = factory((s) => Buffer.from(s, 'binary').toString('base64'));

const nodeSha256b64 = (s) => createHash('sha256').update(s, 'utf8').digest('base64');
const nodeAuth = (p, salt, ch) => nodeSha256b64(nodeSha256b64(p + salt) + ch);

let failures = 0;
const check = (label, got, want) => {
  const ok = got === want;
  if (!ok) failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok) console.log(`      got  ${got}\n      want ${want}`);
};

// 1. Known SHA-256 test vectors.
check('sha256("abc")', sha256b64('abc'), 'ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=');
check('sha256("")', sha256b64(''), '47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=');
check('sha256(1000-char)', sha256b64('x'.repeat(1000)), nodeSha256b64('x'.repeat(1000)));

// 2. OBS auth string, using a real salt/challenge shape (base64, 44 chars).
const salt = Buffer.from('FHDleVLT0MfAB/AZr9n3Lvs+q8ZPuxwckbI7vC179R4=', 'base64').toString('base64');
const challenge = Buffer.from('Rz9Wjd7LjeD02lUxgzgAC6sxsO1HWT9zVtnsYwmDmb0=', 'base64').toString('base64');
check('obsAuth matches node', obsAuth('C8RsC84pViTVESA5', salt, challenge), nodeAuth('C8RsC84pViTVESA5', salt, challenge));

// 3. Multi-block input (crosses the 64-byte block boundary the page's padding code handles).
const long = 'a'.repeat(200);
check('sha256(200-char)', sha256b64(long), nodeSha256b64(long));

console.log(failures === 0 ? '\nall checks passed' : `\n${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
