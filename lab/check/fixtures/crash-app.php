<?php
// A server that dies at boot: for the checks that a harness removes its containers when the server it started is gone.
fwrite(STDERR, "crash-app: exiting at boot\n");
exit(3);
