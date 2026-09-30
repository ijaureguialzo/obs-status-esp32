#!/usr/bin/env python3
"""
Rename firmware binary from .pio/build/<env>/firmware.bin
to a standard obs-status-firmware.bin for easy flashing.
"""

import os
import shutil
import sys

def rename_firmware(build_dir=".pio/build"):
    """Rename firmware binary to a standard name."""
    if not os.path.isdir(build_dir):
        print(f"Build directory '{build_dir}' not found. Run 'pio run' first.")
        sys.exit(1)
    
    envs = [d for d in os.listdir(build_dir) if os.path.isdir(os.path.join(build_dir, d))]
    if not envs:
        print("No build environments found. Run 'pio run' first.")
        sys.exit(1)
    
    latest_env = max(envs, key=lambda e: os.path.getmtime(os.path.join(build_dir, e)))
    src = os.path.join(build_dir, latest_env, "firmware.bin")
    dst = "obs-status-firmware.bin"
    
    if not os.path.isfile(src):
        print(f"No firmware.bin found in {latest_env}/")
        sys.exit(1)
    
    shutil.copy2(src, dst)
    print(f"Copied {latest_env}/firmware.bin -> {dst}")

if __name__ == "__main__":
    rename_firmware()