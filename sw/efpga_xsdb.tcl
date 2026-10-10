# =============================================================================
# efpga_xsdb.tcl - silicon selftest of efpga_axil over JTAG (no Linux needed)
#
#   xsdb sw/efpga_xsdb.tcl <pdi> <base> <loops> <d1.hex> [<d2.hex> ...]
#   (legacy: xsdb sw/efpga_xsdb.tcl <pdi> <counter14.hex> <lfsr14.hex> [base] [loops])
#
# 1) system reset + programs the PDI (PLM + CIPS + PL incl. the eFPGA)
# 2) selects the APU target for access to the PS address map
# 3) reads ID, measures the fabric clock, then runs the same selftest as
#    sw/efpga.py: configure d1 -> d2 -> ... -> d1 and compare IO_PULSE results.
# Expected values: <design>.expect next to the .hex (golden RTL sim), built in
# for counter14 / lfsr14:
#           counter14 n=1:0001 n=1000:03e8 n=16383:3fff
#           lfsr14    n=1:0002 n=1000:1cda n=16383:0001
# =============================================================================
proc usage {} {
    puts "usage: xsdb efpga_xsdb.tcl <pdi> <base> <loops> <d1.hex> \[<d2.hex> ...\]"
    exit 1
}
if {[llength $argv] < 3} { usage }
set PDI [lindex $argv 0]
if {[string match "*.hex" [lindex $argv 1]]} {
    # legacy argument order
    set DESIGNS [lrange $argv 1 2]
    set BASE  [expr {[llength $argv] > 3 ? [lindex $argv 3] : 0xA4000000}]
    set LOOPS [expr {[llength $argv] > 4 ? [lindex $argv 4] : 1}]
} else {
    if {[llength $argv] < 4} { usage }
    set BASE    [lindex $argv 1]
    set LOOPS   [lindex $argv 2]
    set DESIGNS [lrange $argv 3 end]
}

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

proc builtin_expect {design n} {
    if {$design eq "counter14"} { return [expr {$n & 0x3FFF}] }
    set s 1
    for {set i 0} {$i < $n} {incr i} {
        set fb [expr {(($s >> 13) ^ ($s >> 12) ^ ($s >> 11) ^ ($s >> 1)) & 1}]
        set s  [expr {(($s << 1) | $fb) & 0x3FFF}]
    }
    return $s
}

# list of {n value} pairs: <design>.expect if present, else built-in model
proc expectations {hex} {
    set name [file rootname [file tail $hex]]
    set ef   [file rootname $hex].expect
    set pairs {}
    if {[file exists $ef]} {
        set fh [open $ef r]
        foreach line [split [read $fh] "\n"] {
            if {[llength $line] == 2} { lappend pairs [list [lindex $line 0] [expr {"0x[lindex $line 1]"}]] }
        }
        close $fh
    } elseif {$name eq "counter14" || $name eq "lfsr14"} {
        foreach n {1 1000 16383} { lappend pairs [list $n [builtin_expect $name $n]] }
    } else {
        error "$hex: no [file tail $ef] and no built-in model for '$name'"
    }
    return $pairs
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
foreach d $DESIGNS {
    set WORDS($d) [load_hex $d]
    set EXP($d)   [expectations $d]
}
set order [concat $DESIGNS [lrange $DESIGNS 0 0]]
set errors 0
for {set loop 0} {$loop < $LOOPS} {incr loop} {
    foreach d $order {
        set name [file rootname [file tail $d]]
        set dt [configure $WORDS($d)]
        set oe [rd IO_OE]
        if {$oe != 0xFFFC} { puts [format "  %s IO_OE=0x%04x expected 0xfffc" $name $oe]; incr errors }
        set line ""
        foreach pair $EXP($d) {
            lassign $pair n exp
            wr IO_PULSE [expr {(1 << 16) | 0x3}]; wait_pulse
            wr IO_PULSE [expr {($n << 16) | 0x2}]; wait_pulse
            set got [expr {([rd IO_OUT] >> 2) & 0x3FFF}]
            if {$got != $exp} { incr errors; append line [format " n=%d:%04x!=%04x" $n $got $exp] } \
            else              { append line [format " n=%d:%04x" $n $got] }
        }
        puts [format "\[loop %d\] %-9s cfg %d words in %d ms %s" $loop $name [llength $WORDS($d)] $dt $line]
    }
}
puts [expr {$errors == 0 ? "RESULT: PASS" : "RESULT: FAIL ($errors errors)"}]
exit [expr {$errors != 0}]
