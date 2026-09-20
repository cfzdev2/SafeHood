'use strict';

const {
  spawn,
} = require('node:child_process');

const path =
  require('node:path');

const WORKER_PATH =
  path.join(
    __dirname,
    'authenticated_index.js',
  );

const INITIAL_RESTART_DELAY_MS = 1000;
const MAX_RESTART_DELAY_MS = 30000;
const STABLE_UPTIME_MS = 60000;
const FORCE_STOP_DELAY_MS = 15000;

let worker = null;
let restartTimer = null;
let forceStopTimer = null;
let shuttingDown = false;
let restartDelayMs =
  INITIAL_RESTART_DELAY_MS;
let workerStartedAt = 0;

function startWorker() {
  if (shuttingDown) {
    return;
  }

  workerStartedAt = Date.now();

  const nextWorker =
    spawn(
      process.execPath,
      [
        WORKER_PATH,
      ],
      {
        cwd:
          __dirname,

        env:
          process.env,

        stdio:
          'inherit',
      },
    );

  worker = nextWorker;

  console.log(
    '[BRIDGE SUPERVISOR] uruchomiono worker, ' +
    `PID = ${nextWorker.pid}`,
  );

  nextWorker.once(
    'error',
    (error) => {
      console.error(
        '[BRIDGE SUPERVISOR] błąd uruchamiania: ' +
        `${error.message}`,
      );
    },
  );

  nextWorker.once(
    'close',
    (code, signal) => {
      if (worker === nextWorker) {
        worker = null;
      }

      if (forceStopTimer) {
        clearTimeout(forceStopTimer);
        forceStopTimer = null;
      }

      if (shuttingDown) {
        console.log(
          '[BRIDGE SUPERVISOR] zatrzymano',
        );

        process.exit(0);
      }

      const uptime =
        Date.now() - workerStartedAt;

      if (uptime >= STABLE_UPTIME_MS) {
        restartDelayMs =
          INITIAL_RESTART_DELAY_MS;
      }

      const delay =
        restartDelayMs;

      restartDelayMs =
        Math.min(
          restartDelayMs * 2,
          MAX_RESTART_DELAY_MS,
        );

      console.error(
        '[BRIDGE SUPERVISOR] worker zakończony, ' +
        `code = ${code ?? '-'}, ` +
        `signal = ${signal ?? '-'}. ` +
        `Restart za ${delay} ms.`,
      );

      restartTimer =
        setTimeout(
          () => {
            restartTimer = null;
            startWorker();
          },
          delay,
        );
    },
  );
}

function shutdown(signal) {
  if (shuttingDown) {
    return;
  }

  shuttingDown = true;

  if (restartTimer) {
    clearTimeout(restartTimer);
    restartTimer = null;
  }

  console.log(
    `\n[BRIDGE SUPERVISOR] zatrzymywanie: ${signal}`,
  );

  const activeWorker =
    worker;

  if (!activeWorker) {
    process.exit(0);
    return;
  }

  if (process.platform !== 'win32') {
    activeWorker.kill(signal);
  }

  forceStopTimer =
    setTimeout(
      () => {
        if (worker === activeWorker) {
          console.error(
            '[BRIDGE SUPERVISOR] wymuszam zatrzymanie workera',
          );

          activeWorker.kill('SIGKILL');
        }
      },
      FORCE_STOP_DELAY_MS,
    );
}

process.on(
  'SIGINT',
  () => {
    shutdown('SIGINT');
  },
);

process.on(
  'SIGTERM',
  () => {
    shutdown('SIGTERM');
  },
);

startWorker();