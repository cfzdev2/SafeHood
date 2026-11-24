'use strict';

const fs = require('node:fs');
const path = require('node:path');

const tasksPath = path.join(__dirname, '..', '.vscode', 'tasks.json');
const firebaseLabel = 'SafeHood - Firebase';
const bridgeLabel = 'SafeHood - Bridge';
const stackLabel = 'SafeHood - Start Dev Stack';

function readTasks(source) {
  // VS Code accepts JSON with comments and trailing commas. Keep string
  // literals intact, including URLs and commands that contain //.
  const withoutComments = source.replace(
    /"(?:\\[\s\S]|[^"\\])*"|(\/\/[^\r\n]*|\/\*[\s\S]*?\*\/)/g,
    (token, comment) => comment ? ' ' : token,
  );
  return JSON.parse(withoutComments.replace(
    /"(?:\\[\s\S]|[^"\\])*"|,(?=\s*[}\]])/g,
    (token) => token === ',' ? '' : token,
  ));
}

function main() {
  let config = {version: '2.0.0', tasks: []};
  if (fs.existsSync(tasksPath)) {
    try {
      config = readTasks(fs.readFileSync(tasksPath, 'utf8').replace(/^\uFEFF/, ''));
    } catch {
      throw new Error('Nie udało się odczytać .vscode/tasks.json. Plik nie został zmieniony.');
    }
  }
  if (config.version !== '2.0.0' || !Array.isArray(config.tasks)) {
    throw new Error('Nieprawidłowy format zadań VS Code. Plik nie został zmieniony.');
  }
  const oldFirebase = config.tasks.find((task) => task?.label === firebaseLabel);
  const firebase = {
    ...oldFirebase,
    label: firebaseLabel,
    type: 'shell', command: 'node tools/start_dev_firebase.cjs',
    options: {...oldFirebase?.options, cwd: '${workspaceFolder}'},
    isBackground: true, problemMatcher: [],
    presentation: {...oldFirebase?.presentation, reveal: 'always', panel: 'dedicated'},
    runOptions: {instanceLimit: 1},
  };
  const original = JSON.stringify(config);
  const oldBridge = config.tasks.find((task) => task?.label === bridgeLabel);
  const shell = oldBridge?.options?.shell ?? firebase.options?.shell;
  const bridge = {
    label: bridgeLabel,
    type: 'shell',
    command: 'node tools/start_dev_bridge.cjs',
    options: {
      cwd: '${workspaceFolder}',
      ...(shell ? {shell} : {}),
      ...(oldBridge?.options?.env ? {env: oldBridge.options.env} : {}),
    },
    isBackground: true,
    problemMatcher: [],
    presentation: {
      reveal: 'always',
      panel: 'dedicated',
      showReuseMessage: false,
      ...oldBridge?.presentation,
    },
    runOptions: {instanceLimit: 1},
  };
  const stack = {
    label: stackLabel,
    dependsOn: [firebaseLabel, bridgeLabel],
    dependsOrder: 'parallel',
    problemMatcher: [],
    runOptions: {runOn: 'folderOpen', instanceLimit: 1},
  };
  for (const replacement of [firebase, bridge, stack]) {
    const index = config.tasks.findIndex((task) => task?.label === replacement.label);
    if (index === -1) config.tasks.push(replacement);
    else config.tasks[index] = replacement;
  }
  for (const task of config.tasks) {
    if (typeof task?.label === 'string' && task.label.startsWith('SafeHood - ') &&
        task.label !== stackLabel && task.runOptions?.runOn === 'folderOpen') {
      task.runOptions.runOn = 'default';
    }
  }

  if (JSON.stringify(config) === original) {
    console.log('Zadania SafeHood są już aktualne.');
    return;
  }

  const backup = path.join(path.dirname(tasksPath), `tasks.${Date.now()}.json.bak`);
  const temporary = `${tasksPath}.${process.pid}.tmp`;
  fs.mkdirSync(path.dirname(tasksPath), {recursive: true});
  const hadTasks = fs.existsSync(tasksPath);
  if (hadTasks) fs.copyFileSync(tasksPath, backup, fs.constants.COPYFILE_EXCL);
  fs.writeFileSync(temporary, `${JSON.stringify(config, null, 2)}\n`, {flag: 'wx'});
  try {
    fs.renameSync(temporary, tasksPath);
  } finally {
    fs.rmSync(temporary, {force: true});
  }
  console.log('Autostart SafeHood: Firebase i Bridge. Atrapy, strumienie i Flutter uruchamiasz ręcznie.');
  if (hadTasks) console.log(`Kopia poprzednich zadań: .vscode/${path.basename(backup)}`);
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
