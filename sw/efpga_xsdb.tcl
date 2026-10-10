# =============================================================================
# efpga_xsdb.tcl - silicon selftest of efpga_axil over JTAG (no Linux needed)
#
#   xsdb sw/efpga_xsdb.tcl <pdi> <counter14.hex> <lfsr14.hex> [base] [loops]
#
# 1) programs the PDI (PLM + CIPS + PL incl. the eFPGA)
# 2) selects a target with access to the PS address map
# 3) reads ID, measures the fabric clock, then runs the same selftest as
#    sw/efpga.py: configure A -> B -> A and compare IO_PULSE results with the
#    signatures from simulation.
# Expected: counter14 n=1:0001 n=1000:03e8 n=16383:3fff
#           lfsr14    n=1:0002 n=1000:1cda n=16383:0001
# =============================================================================
if {[llength $argv] < 3} {
    puts "usage: xsdb efpga_xsdb.tcl <pdi> <counter14.hex> <lfsr14.hex> \[base\] \[loops\]"
    exit 1
}
set PDI   [lindex $argv 0]
set HEX_A [lindex $argv 1]
set HEX_B [lindex $argv 2]
set BASE  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0xA4000000}]
set LOOPS [expr {[llength $argv] > 4 ? [lindex $argv 4] : 1}]

set R(ID) 0x00; set R(CTRL) 0x04; set R(STATUS) 0x08; set R(CFG_DATA) 0x0C
set R(CFG_COUNT) 0x10; set R(IO_IN) 0x14; set R(IO_OUT) 0x18; set R(IO_OE) 0x1C
set R(CYCLES) 0x24; set R(IO_PULSE) 0x28

proc wr {name v} { global BASE R; mwr -force [expr {$BASE + $R($name)}] [expr {$v & 0xFFFFFFFF}] }
proc rd {name}   { global BASE R; return [mrd -force -value [expr {$BASE + $R($name)}]] }

proc load_hex {path} {
    set fh [open $path r]; set words {}
    foreach line [split [read $fh] "\n"] {
        set line [string trim $line]
        if {$line ne ""} { lappend words [expr {"0x$line"}] }
    }
    close $fh
    return $words
}

proc wait_pulse {} {
    for {set i 0} {$i < 1000} {incr i} {
        if {([rd STATUS] & 0x8) == 0} { return }
    }
    error "PULSE_BUSY stuck, STATUS=[format 0x%08x [rd STATUS]]"
}

proc configure {words} {
    wr CTRL 0x3
    set t0 [clock milliseconds]
    foreach w $words { wr CFG_DATA $w }
    set dt [expr {[clock milliseconds] - $t0}]
    set n [rd CFG_COUNT]
    if {$n != [llength $words]} { error "CFG_COUNT=$n expected [llength $words]" }
    wr IO_IN 0
    wr CTRL 0x0
    return $dt
}

proc expect {design n} {
    if {$design eq "counter14"} { return [expr {$n & 0x3FFF}] }
    set s 1
    for {set i 0} {$i < $n} {incr i} {
        set fb [expr {(($s >> 13) ^ ($s >> 12) ^ ($s >> 11) ^ ($s >> 1)) & 1}]
        set s  [expr {(($s << 1) | $fb) & 0x3FFF}]
    }
    return $s
}

# ---------------------------------------------------------------- program + target
connect
puts "== targets"; puts [targets]
targets -set -nocase -filter {name =~ "*Versal*"}
rst -system
after 1500
targets -set -nocase -filter {name =~ "PMC"}
puts "== programming $PDI"
device program $PDI
after 2000
# APU gives access to the PS address map (M_AXI_FPD -> PL)
targets -set -nocase -filter {name =~ "APU*"}
puts "== using target:"; puts [targets]

set id [rd ID]
if {$id != 0xEF0A0001} {
    puts [format "ID=0x%08x, expected 0xef0a0001 - wrong base or target?" $id]
    exit 1
}
set c0 [rd CYCLES]; after 200; set c1 [rd CYCLES]
puts [format "ID=0x%08x  fabric clock ~%.2f MHz" $id [expr {(($c1 - $c0) & 0xFFFFFFFF) / 0.2 / 1e6}]]

# ---------------------------------------------------------------- selftest
set A [load_hex $HEX_A]; set B [load_hex $HEX_B]
set errors 0
for {set loop 0} {$loop < $LOOPS} {incr loop} {
    foreach {name words} [list counter14 $A lfsr14 $B counter14 $A] {
        set dt [configure $words]
        set oe [rd IO_OE]
        if {$oe != 0xFFFC} { puts [format "  %s IO_OE=0x%04x expected 0xfffc" $name $oe]; incr errors }
        set line ""
        foreach n {1 1000 16383} {
            wr IO_PULSE [expr {(1 << 16) | 0x3}]; wait_pulse
            wr IO_PULSE [expr {($n << 16) | 0x2}]; wait_pulse
            set got [expr {([rd IO_OUT] >> 2) & 0x3FFF}]
            set exp [expect $name $n]
            if {$got != $exp} { incr errors; append line [format " n=%d:%04x!=%04x" $n $got $exp] } \
            else              { append line [format " n=%d:%04x" $n $got] }
        }
        puts [format "\[loop %d\] %-9s cfg %d words in %d ms %s" $loop $name [llength $words] $dt $line]
    }
}
puts [expr {$errors == 0 ? "RESULT: PASS" : "RESULT: FAIL ($errors errors)"}]
exit [expr {$errors != 0}]
