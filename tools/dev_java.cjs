'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

function envValue(env, name) {
  const key = Object.keys(env).find((key) => key.toUpperCase() === name.toUpperCase());
  return key ? env[key] : '';
}

function javaMajor(output) {
  const version = /^\s*(?:openjdk|java)\s+version\s+"(?:1\.)?(\d+)(?:[."\s+-]|$)/im
    .exec(output) || /^\s*(?:openjdk|java)\s+(?:1\.)?(\d+)\.\d+/im.exec(output);
  return version ? Number(version[1]) : null;
}

function normalizeHome(value, platform) {
  let home = String(value || '').trim().replace(/^"(.*)"$/, '$1');
  if (platform === 'win32') home = home.replace(/^\/([a-z])\//i, (_, drive) => `${drive}:/`);
  return home;
}

function resolveJava({env = process.env, platform = process.platform,
  fileSystem = fs, run = spawnSync, minimumMajor = 21} = {}) {
  const paths = platform === 'win32' ? path.win32 : path.posix;
  const delimiter = platform === 'win32' ? ';' : ':';
  const executable = platform === 'win32' ? 'java.exe' : 'java';
  const originalPath = envValue(env, 'PATH');
  const seen = new Set();
  let oldVersion = null;
  const exists = (filename) => {
    try { return fileSystem.statSync(filename).isFile(); } catch (_) { return false; }
  };
  const configuredEnv = (home) => {
    const prepared = {...env};
    for (const key of Object.keys(prepared)) {
      if (['PATH', 'JAVA_HOME'].includes(key.toUpperCase())) delete prepared[key];
    }
    if (home) prepared.JAVA_HOME = home;
    prepared.PATH = home ? `${paths.join(home, 'bin')}${delimiter}${originalPath}` : originalPath;
    return prepared;
  };
  const probe = (command, home = null) => {
    const key = platform === 'win32' ? command.toLowerCase() : command;
    if (seen.has(key)) return null;
    seen.add(key);
    const candidateEnv = configuredEnv(home);
    let result;
    try {
      result = run(command, ['-XshowSettings:properties', '-version'], {
        env: candidateEnv, encoding: 'utf8', timeout: 4000,
        maxBuffer: 128 * 1024, windowsHide: true, shell: false,
      });
    } catch (_) { return null; }
    if (result.error || result.status !== 0) return null;
    const output = String(result.stderr || '') + '\n' + String(result.stdout || '');
    const major = javaMajor(output);
    if (!major || major < minimumMajor) {
      if (major) oldVersion = Math.max(oldVersion || 0, major);
      return null;
    }
    const runtimeHome = normalizeHome(/^\s*java\.home\s*=\s*(.+)$/m.exec(output)?.[1], platform);
    const selectedHome = runtimeHome && exists(paths.join(runtimeHome, 'bin', executable))
      ? runtimeHome : home;
    return {major, home: selectedHome, command, env: configuredEnv(selectedHome)};
  };
  const probeHome = (home) => {
    home = normalizeHome(home, platform);
    if (!home) return null;
    const command = paths.join(home, 'bin', executable);
    return exists(command) ? probe(command, home) : null;
  };

  for (const variable of ['JAVA_HOME', 'JDK_HOME', 'STUDIO_JDK']) {
    const found = probeHome(envValue(env, variable));
    if (found) return found;
  }
  const fromPath = probe('java');
  if (fromPath) return fromPath;
  // Probe concrete executables too: Windows shims or shell PATH conversion can
  // prevent spawning "java" even when a JDK is already installed.
  for (const directory of originalPath.split(delimiter).filter(Boolean)) {
    const command = paths.join(directory.replace(/^"(.*)"$/, '$1'), executable);
    if (exists(command)) {
      const found = probe(command, paths.dirname(paths.dirname(command)));
      if (found) return found;
    }
  }
  if (platform === 'win32') {
    const programs = [...new Set([
      envValue(env, 'ProgramW6432'), envValue(env, 'ProgramFiles'),
      envValue(env, 'ProgramFiles(x86)'),
    ].filter(Boolean))];
    const local = envValue(env, 'LOCALAPPDATA');
    const user = envValue(env, 'USERPROFILE');
    const homes = [];
    for (const directory of programs) {
      homes.push(paths.join(directory, 'Android', 'Android Studio', 'jbr'),
        paths.join(directory, 'Android', 'Android Studio Preview', 'jbr'));
    }
    if (local) homes.push(paths.join(local, 'Programs', 'Android Studio', 'jbr'),
      paths.join(local, 'Android', 'Android Studio', 'jbr'));
    for (const home of homes) {
      const found = probeHome(home);
      if (found) return found;
    }
    const roots = programs.flatMap((directory) => ['Java', 'Eclipse Adoptium',
      'Microsoft', 'Amazon Corretto', 'BellSoft', 'Semeru'].map((name) => paths.join(directory, name)));
    if (user) roots.push(paths.join(user, '.jdks'));
    for (const directory of roots) {
      let entries;
      try { entries = fileSystem.readdirSync(directory, {withFileTypes: true}); } catch (_) { continue; }
      for (const entry of entries.slice(0, 64)) {
        if (!entry.isDirectory()) continue;
        const found = probeHome(paths.join(directory, entry.name));
        if (found) return found;
      }
    }
    // Android Studio installed to a different drive can register its location.
    for (const key of ['HKLM\\SOFTWARE\\Android Studio', 'HKCU\\SOFTWARE\\Android Studio']) {
      let result;
      try {
        result = run('reg.exe', ['query', key, '/v', 'Path'], {
          env, encoding: 'utf8', timeout: 2000, windowsHide: true, shell: false,
        });
      } catch (_) { continue; }
      if (result.error || result.status !== 0) continue;
      const studio = /^\s*Path\s+REG_(?:EXPAND_)?SZ\s+(.+)$/mi.exec(result.stdout || '')?.[1];
      if (studio) {
        const expanded = studio.trim().replace(/%([^%]+)%/g, (value, name) => envValue(env, name) || value);
        const found = probeHome(paths.join(expanded, 'jbr'));
        if (found) return found;
      }
    }
  }
  const reason = oldVersion ? `Znaleziono tylko Javę ${oldVersion}.` : 'Nie znaleziono działającej Javy.';
  const error = new Error(`${reason} Firebase wymaga Javy ${minimumMajor} lub nowszej. ` +
    'Sprawdź instalację Android Studio/JDK i wynik „flutter doctor -v”.');
  error.code = 'SAFEHOOD_JAVA_UNAVAILABLE';
  throw error;
}

if (require.main === module) {
  try {
    const java = resolveJava();
    console.log(`[SafeHood] Java ${java.major}: ${java.home || java.command}`);
  } catch (error) {
    console.error(`[SafeHood] ${error.message}`);
    process.exitCode = 1;
  }
}

module.exports = {resolveJava, javaMajor, normalizeHome};
