version       = "0.1.0"
author        = "Luciano Federico Pereira"
description   = "Canonical JSON normalizer (byte-identical to the Python reference)"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["jsoncanon_cli"]

requires "nim >= 1.6.0"
