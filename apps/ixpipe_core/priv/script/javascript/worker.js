'use strict';
// The Script tool's JavaScript worker: portals starts it with the socket path last.
const { Worker } = require('portals-worker');

new Worker({ maxConcurrency: 1, modules: { ixpipe_runner: require('./ixpipe_runner') } })
  .run()
  .catch((err) => {
    process.stderr.write(`${err.stack}\n`);
    process.exit(1);
  });
