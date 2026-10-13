if [ -n "$PETALINUX" ] || echo "$PATH" | grep -qi petalinux; then
    echo "WARNING: PetaLinux environment loaded in this shell - use a clean terminal for ~/FPGA"
fi
source ~/FPGA/.venv/bin/activate
cd ~/FPGA
export _LLN_OVERRIDE_YOSYS="/home/adrian/FPGA/scripts/yosys-pyosys"
export PYTHONPATH="$HOME/FPGA/.venv/lib/python3.12/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export CTS_NO_INSERTION_DELAY=1
export NATIVE_YOSYS=/data/adrian/tools/yosys066/yosys
