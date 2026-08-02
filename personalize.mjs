#!/usr/bin/env node
/**
 * personalize.mjs — deterministic placeholder substitution (F-3 fix).
 *
 * Replaces {{PLACEHOLDER}} tokens in vault files with validated values.
 * Literal string replacement only — no shell, no sed, no eval. User input can
 * never become executed code, and bad input fails BEFORE any file is touched.
 *
 * Usage:
 *   node personalize.mjs --vault <path> --os-name <s> --user-name <s> \
 *        --user-bio <s> --companion <s> [--today YYYY-MM-DD] [--dry-run]
 */
import { lstatSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { isAbsolute, join, relative } from 'node:path';

// --- Arg parsing -------------------------------------------------------------
const args = {};
const BOOLEAN_FLAGS = new Set(['dry-run']);
const VALUE_FLAGS = new Set(['vault', 'os-name', 'user-name', 'user-bio', 'companion', 'today']);
for (let i = 2; i < process.argv.length; i++) {
  const key = process.argv[i];
  if (!key.startsWith('--')) fail(`beklenmeyen argüman: ${key}`);
  const name = key.slice(2);
  if (!BOOLEAN_FLAGS.has(name) && !VALUE_FLAGS.has(name)) fail(`bilinmeyen bayrak: --${name}`);
  if (Object.hasOwn(args, name)) fail(`yinelenen bayrak: --${name}`);
  if (BOOLEAN_FLAGS.has(name)) {
    args[name] = true;
    continue;
  }
  const value = process.argv[i + 1];
  if (!value || value.startsWith('--')) fail(`--${name} için değer gerekli`);
  args[name] = value;
  i++;
}

function fail(msg) {
  console.error(`❌ personalize: ${msg}`);
  process.exit(1);
}

const VAULT_INPUT = args.vault || fail('--vault gerekli');
const DRY_RUN = process.argv.includes('--dry-run');
const TODAY = args.today || new Date().toISOString().slice(0, 10);

let VAULT;
try {
  VAULT = realpathSync(VAULT_INPUT);
} catch (e) {
  fail(`vault yolu çözümlenemedi: ${e.message}`);
}

const REQUIRED_MARKERS = [
  'CLAUDE.md',
  'Open-SecondBrain.ps1',
  join('.claude', 'hooks', 'hooks.mjs'),
  join('.claude', 'hook-manifest.json'),
  join('.claude', 'settings.hooks.example.json'),
  join('🎯 100-Command-Center', 'Dashboard.md'),
];
for (const marker of REQUIRED_MARKERS) {
  const full = join(VAULT, marker);
  try {
    const st = lstatSync(full);
    if (!st.isFile() || st.isSymbolicLink() || st.nlink !== 1) {
      fail(`geçersiz scaffold işaretçisi: ${marker}`);
    }
  } catch (e) {
    fail(`hedef doğrulanmış second-brainbro scaffold'u değil (${marker}): ${e.message}`);
  }
}

// --- Input validation (allowlist — the F-3 control the bash pipeline lacked) -
const NAME_RE = /^[A-Za-zÇĞİÖŞÜçğıöşü0-9 .'_-]{1,64}$/;
const BIO_MAX = 500;

function validateName(field, value) {
  if (!value || !NAME_RE.test(value)) {
    fail(`${field} geçersiz. İzin verilen: harf/rakam/boşluk/'._- (en fazla 64 karakter, satır sonu yok). Alınan: ${JSON.stringify(value)}`);
  }
  return value;
}

function validateBio(value) {
  if (!value) fail('USER_BIO boş olamaz');
  if (value.length > BIO_MAX) fail(`USER_BIO ${BIO_MAX} karakteri aşıyor (${value.length})`);
  // Block template and shell-control syntax. Semantic prompt injection is a
  // separate trust-boundary problem documented in THREAT_MODEL.md.
  const banned = [/(\r|\n)/, /\{\{/, /\}\}/, /`/, /\$\(/];
  for (const re of banned) {
    if (re.test(value)) fail(`USER_BIO yasaklı içerik barındırıyor (${re}): satır sonu, {{ }}, backtick veya $() kullanılamaz.`);
  }
  return value;
}

function validateDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) fail(`TODAY YYYY-MM-DD olmalı, alınan: ${value}`);
  const parsed = new Date(`${value}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
    fail(`TODAY geçerli bir takvim tarihi olmalı, alınan: ${value}`);
  }
  return value;
}

function validateOsName(value) {
  const name = validateName('OS_NAME', value);
  const windowsReserved = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;
  if (name === '.' || name === '..' || windowsReserved.test(name) || /[ .]$/.test(name)) {
    fail(`OS_NAME Windows dosya adı olarak güvenli değil: ${JSON.stringify(name)}`);
  }
  return name;
}

const VALUES = {
  OS_NAME: validateOsName(args['os-name'] || fail('--os-name gerekli')),
  USER_NAME: validateName('USER_NAME', args['user-name'] || fail('--user-name gerekli')),
  USER_BIO: validateBio(args['user-bio'] || ''),
  COMPANION: validateName('COMPANION', args.companion || fail('--companion gerekli')),
  TODAY: validateDate(TODAY),
};

// --- Fixed allowlist: personalization never walks an existing vault ----------
const PERSONALIZE_FILES = [
  'CLAUDE.md',
  join('🎯 100-Command-Center', 'Dashboard.md'),
  join('📋 Templates', 'Note.md'),
  join('🔮 850-Companion', 'Core.md'),
  join('🔮 850-Companion', 'Journal.md'),
  join('🔮 850-Companion', 'Last-Session.md'),
  join('🔮 850-Companion', 'Threads.md'),
];

function safeFile(rel) {
  const full = join(VAULT, rel);
  const relToVault = relative(VAULT, full);
  if (!relToVault || relToVault.startsWith('..') || isAbsolute(relToVault)) fail(`vault dışı yol reddedildi: ${rel}`);
  let st;
  try { st = lstatSync(full); } catch (e) { fail(`beklenen scaffold dosyası okunamadı (${rel}): ${e.message}`); }
  if (!st.isFile() || st.isSymbolicLink() || st.nlink !== 1) {
    fail(`normal ve tek-bağlantılı dosya olmayan hedef reddedildi: ${rel}`);
  }
  if (st.size > 1024 * 1024) fail(`dosya boyutu sınırı aşıldı: ${rel}`);
  const canonical = realpathSync(full);
  const canonicalRel = relative(VAULT, canonical);
  if (!canonicalRel || canonicalRel.startsWith('..') || isAbsolute(canonicalRel)) fail(`vault dışına çözümlenen yol reddedildi: ${rel}`);
  return canonical;
}

const TOKEN_RE = /\{\{(OS_NAME|USER_NAME|USER_BIO|COMPANION|TODAY)\}\}/g;

const planned = [];
const remaining = [];
for (const rel of PERSONALIZE_FILES) {
  const file = safeFile(rel);
  const text = readFileSync(file, 'utf8');
  TOKEN_RE.lastIndex = 0;
  const next = text.replace(TOKEN_RE, (_, name) => VALUES[name]);
  const leftovers = next.match(/\{\{[^}]*\}\}/g);
  if (leftovers) remaining.push(`${rel}: ${leftovers.join(', ')}`);
  if (next !== text) planned.push({ file, rel, next });
}

// Preflight completes before the first write.
if (remaining.length) {
  fail(`doldurulmamış placeholder kaldı:\n  ${remaining.join('\n  ')}`);
}
for (const { file, rel, next } of planned) {
  if (!DRY_RUN) writeFileSync(file, next, 'utf8');
  console.log(`${DRY_RUN ? '[dry-run] ' : ''}✓ ${rel}`);
}

console.log(`\n${DRY_RUN ? '[dry-run] ' : ''}✅ ${planned.length} dosya kişiselleştirildi, placeholder kalmadı.`);
