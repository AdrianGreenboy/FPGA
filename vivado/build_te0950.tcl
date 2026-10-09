# =============================================================================
# build_te0950.tcl - master flow: base project -> copy -> + eFPGA -> PDI + XSA
#
#   vivado -mode batch -source vivado/build_te0950.tcl \
#          -tclargs <base_project.xpr> [freq_mhz] [jobs]
#
# Your base project is NOT modified: it is saved as a copy under
# build/vivado/efpga_te0950/ and the eFPGA is added there.
# Outputs (build/vivado/):
#   efpga_te0950.pdi  efpga_te0950.xsa  efpga_address.txt
#   util_synth.rpt  util_impl.rpt  util_efpga.rpt  timing_summary.rpt  drc.rpt
# =============================================================================
set ROOT [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] < 1} {
    puts "usage: vivado -mode batch -source vivado/build_te0950.tcl -tclargs <base.xpr> \[freq_mhz\] \[jobs\]"
    exit 1
}
set BASE_XPR [file normalize [lindex $argv 0]]
set EFPGA_FREQ_MHZ [expr {[llength $argv] > 1 ? [lindex $argv 1] : 25}]
set JOBS           [expr {[llength $argv] > 2 ? [lindex $argv 2] : 8}]
set OUT  [file join $ROOT build vivado]
set PROJ [file join $OUT efpga_te0950]
file mkdir $OUT

# fabric sources for Vivado (dedup, BRAM model, no ASIC tech-maps)
if {[catch {exec bash [file join $ROOT scripts prepare_sources.sh]} msg]} {
    puts $msg; error "prepare_sources.sh failed"
}
puts $msg

open_project $BASE_XPR
if {[file exists $PROJ]} { file delete -force $PROJ }
save_project_as efpga_te0950 $PROJ -force

set bds [get_files -quiet *.bd]
if {[llength $bds] != 1} { error "expected exactly one block design, found [llength $bds]: $bds" }
open_bd_design [lindex $bds 0]
source [file join $ROOT vivado add_efpga_to_bd.tcl]

# the BD top-level ports do not change, so the existing HDL wrapper stays valid
generate_target all [get_files [lindex $bds 0]]

reset_run synth_1
launch_runs synth_1 -jobs $JOBS
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synthesis failed" }
open_run synth_1
report_utilization -file [file join $OUT util_synth.rpt]
report_utilization -hierarchical -hierarchical_depth 4 -file [file join $OUT util_efpga.rpt]
close_design

launch_runs impl_1 -to_step write_device_image -jobs $JOBS
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "implementation failed" }
open_run impl_1
report_utilization    -file [file join $OUT util_impl.rpt]
report_timing_summary -max_paths 20 -file [file join $OUT timing_summary.rpt]
report_drc            -file [file join $OUT drc.rpt]

set pdi [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.pdi]]
if {[llength $pdi] == 0} { error "no PDI produced" }
file copy -force [lindex $pdi 0] [file join $OUT efpga_te0950.pdi]
write_hw_platform -fixed -force -include_bit [file join $OUT efpga_te0950.xsa]

puts "=================================================================="
puts " eFPGA build done   fabric clock: $EFPGA_FREQ_MHZ MHz"
puts " base address     : [expr {[info exists EFPGA_BASE] ? $EFPGA_BASE : {see efpga_address.txt}}]"
puts " PDI / XSA        : $OUT/efpga_te0950.{pdi,xsa}"
puts " NOTE: negative slack *inside* u_efpga is expected (structural paths through"
puts "       unconfigured routing). Judge the fabric with: sw/efpga.py selftest"
puts "=================================================================="
