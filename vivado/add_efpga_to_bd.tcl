# =============================================================================
# add_efpga_to_bd.tcl - add the eFPGA subsystem to an OPEN Versal block design
#
# Intended for your existing, working TE0950 base design (CIPS configured in the
# GUI, NoC/DDR, PetaLinux). The CIPS itself is NOT modified. Requirements:
#   - CIPS has an AXI master to PL enabled (default: M_AXI_FPD)
#   - a PL reference clock + its reset are available (default: pl0_ref_clk / pl0_resetn)
#   - scripts/prepare_sources.sh has been run (build/src/fpga.f exists)
#
# Optional variables (set before sourcing):
#   EFPGA_ROOT        repo root                     (default: ../ from this file)
#   EFPGA_FREQ_MHZ    fabric + config clock         (default: 25)
#   EFPGA_CIPS        CIPS cell path                (default: auto-detect)
#   EFPGA_AXI_MASTER  master interface pin          (default: <cips>/M_AXI_FPD)
#   EFPGA_AXI_CLK     clock pin of that master      (default: <cips>/m_axi_fpd_aclk)
#   EFPGA_REF_CLK     input clock for the MMCM      (default: <cips>/pl0_ref_clk)
#   EFPGA_REF_RESETN  active-low reset              (default: <cips>/pl0_resetn)
#   EFPGA_CLK_SRC     "wizard" (MMCM in clk_wizard) or the path of an existing
#                     clock pin that already runs at EFPGA_FREQ_MHZ
#
# The master interface may be free (a SmartConnect is added) or already go to a
# SmartConnect (one MI port is added to it). Anything else: point
# EFPGA_AXI_MASTER at a free master interface.
# =============================================================================

proc efpga_default {var value} {
    upvar #0 $var v
    if {![info exists v] || $v eq ""} { set v $value }
}
proc efpga_die {msg} {
    puts "ERROR: \[efpga\] $msg"
    error "efpga: $msg"
}

efpga_default EFPGA_ROOT     [file normalize [file join [file dirname [info script]] ..]]
efpga_default EFPGA_FREQ_MHZ 25
efpga_default EFPGA_CLK_SRC  wizard

if {[current_bd_design -quiet] eq ""} { efpga_die "no block design is open (open_bd_design first)" }

if {![info exists EFPGA_CIPS] || $EFPGA_CIPS eq ""} {
    set cips [get_bd_cells -quiet -hierarchical -filter {VLNV =~ "*:versal_cips:*"}]
    if {[llength $cips] != 1} { efpga_die "found [llength $cips] CIPS cells; set EFPGA_CIPS" }
    set EFPGA_CIPS "/[string trimleft $cips /]"
}
efpga_default EFPGA_AXI_MASTER "$EFPGA_CIPS/M_AXI_FPD"
efpga_default EFPGA_AXI_CLK    "$EFPGA_CIPS/m_axi_fpd_aclk"
efpga_default EFPGA_REF_CLK    "$EFPGA_CIPS/pl0_ref_clk"
efpga_default EFPGA_REF_RESETN "$EFPGA_CIPS/pl0_resetn"

foreach {what pin} [list "AXI master" $EFPGA_AXI_MASTER] {
    if {[get_bd_intf_pins -quiet $pin] eq ""} {
        efpga_die "$what $pin does not exist - enable it in the CIPS GUI (PS-PL interfaces) or set EFPGA_AXI_MASTER"
    }
}
foreach {what pin} [list "AXI clock" $EFPGA_AXI_CLK "ref clock" $EFPGA_REF_CLK "ref reset" $EFPGA_REF_RESETN] {
    if {[get_bd_pins -quiet $pin] eq ""} { efpga_die "$what pin $pin does not exist (enable it in CIPS or set the variable)" }
}
if {[get_bd_cells -quiet /efpga] ne ""} { efpga_die "/efpga already exists in this block design" }

# -----------------------------------------------------------------------------
# 1) sources
# -----------------------------------------------------------------------------
set flist [file join $EFPGA_ROOT build src fpga.f]
if {![file exists $flist]} { efpga_die "$flist missing - run scripts/prepare_sources.sh" }
set fh [open $flist r]; set fabric_files [split [string trim [read $fh]] "\n"]; close $fh
add_files -norecurse -fileset sources_1 $fabric_files
set vhd [file join $EFPGA_ROOT rtl efpga_axil.vhd]
add_files -norecurse -fileset sources_1 $vhd
set_property file_type VHDL [get_files $vhd]   ;# plain VHDL: module references
add_files -norecurse -fileset constrs_1 [file join $EFPGA_ROOT vivado efpga.xdc]
update_compile_order -fileset sources_1
puts "INFO: \[efpga\] added [llength $fabric_files] fabric files + efpga_axil.vhd + efpga.xdc"

# -----------------------------------------------------------------------------
# 2) cells
# -----------------------------------------------------------------------------
create_bd_cell -type hier efpga
create_bd_cell -type module -reference efpga_axil efpga/u_efpga_axil

# fabric clock
if {$EFPGA_CLK_SRC eq "wizard"} {
    set ref_hz [get_property CONFIG.FREQ_HZ [get_bd_pins $EFPGA_REF_CLK]]
    if {$ref_hz eq ""} { efpga_die "cannot read CONFIG.FREQ_HZ of $EFPGA_REF_CLK" }
    set ref_mhz [format %.3f [expr {$ref_hz / 1.0e6}]]
    create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard:* efpga/clk_wiz
    if {[catch {
        set_property -dict [list \
            CONFIG.PRIM_SOURCE {No_buffer} \
            CONFIG.PRIM_IN_FREQ $ref_mhz \
            CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
            CONFIG.CLKOUT_PORT {clk_out1,clk_out2,clk_out3,clk_out4,clk_out5,clk_out6,clk_out7} \
            CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY "$EFPGA_FREQ_MHZ,100.000,100.000,100.000,100.000,100.000,100.000" \
            CONFIG.USE_LOCKED {true} \
            CONFIG.USE_RESET {true} \
            CONFIG.RESET_TYPE {ACTIVE_LOW} \
        ] [get_bd_cells efpga/clk_wiz]
    } err]} {
        efpga_die "clk_wizard configuration failed ($err). Configure efpga/clk_wiz in the GUI\
                   (1 output, $EFPGA_FREQ_MHZ MHz, active-low reset, locked) or use an\
                   existing $EFPGA_FREQ_MHZ MHz clock via EFPGA_CLK_SRC"
    }
    connect_bd_net [get_bd_pins $EFPGA_REF_CLK]    [get_bd_pins efpga/clk_wiz/clk_in1]
    connect_bd_net [get_bd_pins $EFPGA_REF_RESETN] [get_bd_pins efpga/clk_wiz/resetn]
    set fab_clk    [get_bd_pins efpga/clk_wiz/clk_out1]
    set fab_locked [get_bd_pins efpga/clk_wiz/locked]
} else {
    set fab_clk    [get_bd_pins $EFPGA_CLK_SRC]
    set fab_locked ""
}

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* efpga/rst_fab
connect_bd_net $fab_clk [get_bd_pins efpga/rst_fab/slowest_sync_clk]
connect_bd_net [get_bd_pins $EFPGA_REF_RESETN] [get_bd_pins efpga/rst_fab/ext_reset_in]
if {$fab_locked ne ""} { connect_bd_net $fab_locked [get_bd_pins efpga/rst_fab/dcm_locked] }

connect_bd_net $fab_clk [get_bd_pins efpga/u_efpga_axil/aclk]
connect_bd_net [get_bd_pins efpga/rst_fab/peripheral_aresetn] [get_bd_pins efpga/u_efpga_axil/aresetn]

# external pins of the fabric: inputs tied low for now (IN_SEL=0 uses IO_IN)
if {[catch {create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:* efpga/pins_zero}]} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* efpga/pins_zero
}
set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {0}] [get_bd_cells efpga/pins_zero]
connect_bd_net [get_bd_pins efpga/pins_zero/dout] [get_bd_pins efpga/u_efpga_axil/pin_i]

# -----------------------------------------------------------------------------
# 3) AXI: free master -> new SmartConnect; master already on a SmartConnect -> +1 MI
# -----------------------------------------------------------------------------
set mst      [get_bd_intf_pins $EFPGA_AXI_MASTER]
set mst_net  [get_bd_intf_nets -quiet -of_objects $mst]
set axi_clkp [get_bd_pins $EFPGA_AXI_CLK]
if {[get_bd_nets -quiet -of_objects $axi_clkp] eq ""} {
    # master clock pin not driven yet: run the AXI side from the reference clock
    connect_bd_net [get_bd_pins $EFPGA_REF_CLK] $axi_clkp
}
set axi_clk_src [get_bd_pins -quiet -of_objects [get_bd_nets -of_objects $axi_clkp] -filter {DIR == O}]
if {$axi_clk_src eq ""} { set axi_clk_src [get_bd_pins $EFPGA_REF_CLK] }

if {$mst_net eq ""} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* efpga/sc
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1} CONFIG.NUM_CLKS {2}] [get_bd_cells efpga/sc]
    connect_bd_intf_net $mst [get_bd_intf_pins efpga/sc/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins efpga/sc/M00_AXI] [get_bd_intf_pins efpga/u_efpga_axil/s_axi]
    connect_bd_net $axi_clk_src [get_bd_pins efpga/sc/aclk]
    connect_bd_net $fab_clk     [get_bd_pins efpga/sc/aclk1]
    # SmartConnect reset in the AXI master clock domain
    create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* efpga/rst_axi
    connect_bd_net $axi_clk_src [get_bd_pins efpga/rst_axi/slowest_sync_clk]
    connect_bd_net [get_bd_pins $EFPGA_REF_RESETN] [get_bd_pins efpga/rst_axi/ext_reset_in]
    connect_bd_net [get_bd_pins efpga/rst_axi/interconnect_aresetn] [get_bd_pins efpga/sc/aresetn]
} else {
    set peer [get_bd_intf_pins -of_objects $mst_net -filter "PATH != [get_property PATH $mst]"]
    set sc   [get_bd_cells -of_objects $peer]
    if {![string match "*:smartconnect:*" [get_property VLNV $sc]]} {
        efpga_die "$EFPGA_AXI_MASTER already drives $peer (not a SmartConnect); set EFPGA_AXI_MASTER to a free master"
    }
    set n  [get_property CONFIG.NUM_MI $sc]
    set_property CONFIG.NUM_MI [expr {$n + 1}] $sc
    set mi [get_bd_intf_pins $sc/M[format %02d $n]_AXI]
    # put the fabric on its own SmartConnect clock input
    set nclk [get_property CONFIG.NUM_CLKS $sc]
    set_property CONFIG.NUM_CLKS [expr {$nclk + 1}] $sc
    connect_bd_net $fab_clk [get_bd_pins $sc/aclk$nclk]
    connect_bd_intf_net $mi [get_bd_intf_pins efpga/u_efpga_axil/s_axi]
    puts "INFO: \[efpga\] added $mi on existing SmartConnect $sc (clock aclk$nclk)"
}

# -----------------------------------------------------------------------------
# 4) address + validate
# -----------------------------------------------------------------------------
assign_bd_address
set seg [get_bd_addr_segs -quiet -of_objects [get_bd_addr_segs -quiet efpga/u_efpga_axil/s_axi/*]]
if {$seg eq ""} {
    set seg [get_bd_addr_segs -quiet -hierarchical -filter {NAME =~ "*u_efpga_axil*"}]
}
foreach s $seg {
    catch { set_property RANGE 4K $s }
    set EFPGA_BASE [get_property OFFSET $s]
    puts "INFO: \[efpga\] efpga_axil @ $EFPGA_BASE ([get_property RANGE $s]) - $s"
}
file mkdir [file join $EFPGA_ROOT build vivado]
if {[info exists EFPGA_BASE]} {
    set fh [open [file join $EFPGA_ROOT build vivado efpga_address.txt] w]
    puts $fh $EFPGA_BASE; close $fh
}

validate_bd_design
save_bd_design
puts "INFO: \[efpga\] eFPGA subsystem added (fabric clock $EFPGA_FREQ_MHZ MHz)"
