'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {resolveJava, javaMajor, normalizeHome} = require('../dev_java.cjs');

const studio = 'C:\\Program Files\\Android\\Android Studio\\jbr';
const jbr = studio + '\\bin\\java.exe';
const version = (major, home) => ({status: 0,
  stdout: '', stderr: `    java.home = ${home}\nopenjdk version "${major}.0.4"`});

function harness({env = {}, binaries = {}, directories = {}, registry = null} = {}) {
  const calls = [];
  const suppliedEnv = {ProgramFiles: 'C:\\Program Files', Path: 'C:\\Windows\\System32', ...env};
  const fileSystem = {
    statSync: (filename) => {
      if (!binaries[filename]) throw Object.assign(new Error('Not found'), {code: 'ENOENT'});
      return {isFile: () => true};
    },
    readdirSync: (directory) => (directories[directory] || [])
      .map((name) => ({name, isDirectory: () => true})),
  };
  const run = (command, args, options) => {
    calls.push({command, args, options});
    assert.equal(options.shell, false);
    if (command === 'reg.exe' && registry) return registry;
    return binaries[command] || {status: null, error: {code: 'ENOENT'}};
  };
  return {env: suppliedEnv, calls,
    resolve: () => resolveJava({platform: 'win32', env: suppliedEnv, fileSystem, run})};
}

test('a Windows task finds Android Studio Java with spaces and sets only its child environment', () => {
  const h = harness({binaries: {[jbr]: version(21, studio)}});
  const original = {...h.env};
  const java = h.resolve();
  assert.equal(java.major, 21);
  assert.equal(java.env.JAVA_HOME, studio);
  assert.equal(java.env.PATH, studio + '\\bin;C:\\Windows\\System32');
  assert.equal('Path' in java.env, false);
  assert.deepEqual(h.env, original);
  assert.equal(h.calls.filter(({command}) => command === jbr).length, 1);
});

test('an old or broken PATH shim cannot hide a compatible bundled JDK', () => {
  const h = harness({binaries: {java: version(17, 'C:\\old-jdk'),
    [jbr]: version(21, studio)}});
  assert.equal(h.resolve().home, studio);
  const broken = harness({binaries: {java: {status: 1,
    stderr: 'openjdk version "21.0.4"'}, [jbr]: version(21, studio)}});
  assert.equal(broken.resolve().home, studio);
});

test('Git Bash JAVA_HOME is normalized and an explicit working JDK takes precedence', () => {
  assert.equal(normalizeHome('/c/Program Files/JDK', 'win32'), 'c:/Program Files/JDK');
  const home = 'D:\\Java\\jdk-21';
  const h = harness({env: {JAVA_HOME: home}, binaries: {
    [home + '\\bin\\java.exe']: version(21, home), [jbr]: version(23, studio),
  }});
  assert.equal(h.resolve().home, home);
  assert.equal(h.calls.length, 1);
});

test('a JDK on PATH is reused without requiring an Android Studio default path', () => {
  const home = 'D:\\Runtime\\jdk-25';
  const h = harness({binaries: {java: version(25, home),
    [home + '\\bin\\java.exe']: version(25, home)}});
  assert.equal(h.resolve().home, home);
  assert.equal(h.calls.some(({command}) => command === 'reg.exe'), false);
});

test('common standalone JDK installations and another Studio drive are discovered', () => {
  const home = 'C:\\Program Files\\Eclipse Adoptium\\jdk-21';
  const h = harness({directories: {'C:\\Program Files\\Eclipse Adoptium': ['jdk-21']},
    binaries: {[home + '\\bin\\java.exe']: version(21, home)}});
  assert.equal(h.resolve().home, home);
  const other = 'D:\\Developer tools\\Studio\\jbr';
  const custom = harness({binaries: {[other + '\\bin\\java.exe']: version(21, other)},
    registry: {status: 0, stdout: '    Path    REG_SZ    D:\\Developer tools\\Studio\r\n'}});
  assert.equal(custom.resolve().home, other);
  assert.ok(custom.calls.filter(({command}) => command === 'reg.exe')
    .every(({args}) => args[0] === 'query'));
});

test('missing and obsolete Java produce actionable errors without copying JVM output', () => {
  assert.equal(javaMajor('java version "1.8.0_421"'), 8);
  assert.equal(javaMajor('openjdk 21.0.4 2024-07-16'), 21);
  assert.equal(javaMajor('no runtime'), null);
  assert.equal(javaMajor('    java.vm.name = OpenJDK 64-Bit Server VM\n' +
    'openjdk version "17.0.1"\nOpenJDK 64-Bit Server VM'), 17);
  assert.throws(() => harness().resolve(), {code: 'SAFEHOOD_JAVA_UNAVAILABLE'});
  const h = harness({binaries: {java: {...version(17, ''),
    stderr: 'openjdk version "17.0.1"\nPRIVATE-OPTION'}}});
  assert.throws(h.resolve, (error) => error.message.includes('Javę 17') &&
    !error.message.includes('PRIVATE-OPTION'));
});
