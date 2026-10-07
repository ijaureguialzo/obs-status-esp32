"""PlatformIO extra script (pre scope): keep the generated firmware version
header in sync with the git-ignored version.txt at the project root.

The PlatformIO ESP-IDF builder compiles sources itself (from the CMake code
model) and never runs ninja, so the CMake custom command that regenerates
the header does not fire under `pio run`. This script runs the shared
scripts/generate_version.sh and replaces include/firmware_version_generated.h
only when its content actually changed, so:

  - the first build (fresh checkout, no version.txt) gets the committed
    fallback values (1.0.0 / build 1);
  - editing version.txt and re-running `pio run` recompiles the firmware
    with the new values (sources #include the header, so SCons tracks it);
  - builds with an unchanged version.txt stay incremental.

The generated header is git-ignored; this script (re)creates it before
every build so a fresh checkout compiles, and only overwrites it when the
content actually changed so unchanged builds stay incremental.
"""

import os
import subprocess
import tempfile

Import("env")

project_dir = env.subst("$PROJECT_DIR")
project_root = os.path.dirname(os.path.abspath(project_dir))
generator = os.path.join(project_root, "scripts", "generate_version.sh")
header = os.path.join(project_dir, "include", "firmware_version_generated.h")

if not os.path.isfile(generator):
    print("Warning: %s not found; keeping the committed version header" % generator)
else:
    try:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".h", delete=False, dir=project_dir
        ) as tmp:
            tmp_path = tmp.name
        subprocess.run(
            ["sh", generator, "c", tmp_path],
            cwd=project_root,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        new_content = open(tmp_path, "r", encoding="utf-8").read()
        os.unlink(tmp_path)
        try:
            old_content = open(header, "r", encoding="utf-8").read()
        except OSError:
            old_content = None
        if old_content != new_content:
            with open(header, "w", encoding="utf-8") as fp:
                fp.write(new_content)
            print("Firmware version updated: see include/firmware_version_generated.h")
    except (OSError, subprocess.CalledProcessError) as exc:
        print("Warning: could not regenerate the firmware version header: %s" % exc)
