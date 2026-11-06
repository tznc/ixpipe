# The Script tool's Python worker: portals starts it with the socket path last.
from portals import Worker

import ixpipe_runner  # noqa: F401  (imported once, before the first call)

Worker(max_concurrency=1).run()
