<?php
declare(strict_types=1);
// The Script tool's PHP worker: portals starts it with the socket path last.
require __DIR__ . '/IxpipeRunner.php';

(new Portals\Worker(maxConcurrency: 1, modules: ['ixpipe_runner' => IxpipeRunner::class]))->run();
