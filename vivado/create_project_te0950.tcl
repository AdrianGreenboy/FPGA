# Create an empty TE0950 project + block design with an unconfigured CIPS.
# CIPS is configured in the GUI afterwards (deliberately not via TCL).
set ROOT     [file normalize [file join [file dirname [info script]] ..]]
set PROJ_DIR [file join $ROOT build vivado efpga_te0950]
set PART     xcve2302-sfva784-1LP-e-S

if {[llength [get_parts -quiet $PART]] == 0} {
    puts "ERROR: part $PART not installed. Available VE2302 parts:"
    foreach p [get_parts -quiet xcve2302*] { puts "  $p" }
    error "part not found"
}
create_project efpga_te0950 $PROJ_DIR -part $PART -force

set bp [lindex [lsort [get_board_parts -quiet *te0950*]] end]
if {$bp ne ""} {
    set_property board_part $bp [current_project]
    puts "INFO: board part $bp"
} else {
    puts "WARNING: no TE0950 board files found - CIPS/DDR presets must be set by hand"
}
set_property target_language VHDL [current_project]

create_bd_design efpga_bd
create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips:* versal_cips_0
save_bd_design
puts "INFO: project at $PROJ_DIR - now configure versal_cips_0 in the GUI"
