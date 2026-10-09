if [ -n "$PETALINUX" ] || echo "$PATH" | grep -qi petalinux; then
    echo "WARNING: PetaLinux environment loaded in this shell - use a clean terminal for ~/FPGA"
fi
source ~/FPGA/.venv/bin/activate
cd ~/FPGA
