"""PlatformIO extra script (pre scope) for the *-debug environments.

Points the ESP-IDF build at the debug sdkconfig defaults file. The
espressif32 builder does not consume a `sdkconfig` ini option, and this
PlatformIO version ignores `build_env`, so the environment variable is set
in-process: the cmake configure step runs from the same Python process and
inherits it. IDF resolves the path relative to the project root.
"""

import os

Import("env")

project_dir = env.subst("$PROJECT_DIR")
env_var = os.environ.get("SDKCONFIG_DEFAULTS", "")
base = os.path.join(project_dir, "sdkconfig.defaults.debug")
if base not in env_var:
    os.environ["SDKCONFIG_DEFAULTS"] = (env_var + " " + base).strip()
    print("Using debug sdkconfig defaults: %s" % base)
