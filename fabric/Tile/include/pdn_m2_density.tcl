# pdn_m2_density.tcl : tile PDN for IHP SG13G2 = LibreLane's default grid plus
# vertical Metal2 VPWR/VGND straps, for METAL DENSITY, not for IR drop.
#
# The IHP precheck requires >= 25 % Metal2 (+filler) in every 800 x 800 um
# window (M2Fil.h). Inside the area-optimised fabric the tiles' Metal2 routing
# covers 19.5 % and leaves gaps too narrow for filler (PDK filler + the tight
# scripts/ihp_filler.py reach 22.4 %). One 1.2 um strap pair every 50 um adds
# ~4.8 % Metal2 inside the core and ties the Metal1 rails to Metal2 on the way.
# Straps stay inside the core area (no extend_to_boundary) so they never touch
# the tile's N/S Metal2 edge pins.
source $::env(SCRIPTS_DIR)/openroad/common/pdn_cfg.tcl

add_pdn_stripe \
    -grid stdcell_grid \
    -layer Metal2 \
    -width 1.2 \
    -pitch 50 \
    -offset 12 \
    -spacing 1.0 \
    -starts_with POWER

add_pdn_connect -grid stdcell_grid -layers "Metal1 Metal2"
