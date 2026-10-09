#!/usr/bin/env bash
# Launch Vivado with the ~/FPGA venv (and any PetaLinux env) stripped from PATH.
# Vivado's Lopper otherwise picks up .venv/bin/pcpp and dies under Vivado's PYTHONHOME.
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -E '/FPGA/\.venv|[Pp]etalinux' | paste -sd:)
exec env -u VIRTUAL_ENV -u PYTHONPATH -u PYTHONHOME PATH="$CLEAN_PATH" vivado "$@"
