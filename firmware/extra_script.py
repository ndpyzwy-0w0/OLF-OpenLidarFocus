Import("env")
from pathlib import Path

h = Path(env["PROJECT_LIBDEPS_DIR"]) / "s3mini" / "TMCStepper" / "src" / "TMCStepper.h"
if h.exists():
    t = h.read_text(encoding="utf-8", errors="ignore")
    n = t.replace("abort_window = 5;", "abort_window = 50;")
    if n != t:
        h.write_text(n, encoding="utf-8")
        print("patched TMCStepper abort_window=50")
