# =============================================================================
# macprobe_xsdb.tcl - read the silicon MULADD's real multiply function
#
#   xsdb sw/macprobe_xsdb.tcl <pdi> <blk_macprobe.hex> [base] [step]
#
# Loads blk_macprobe (A,B from IO_IN; Q = A*B on IO_OUT, fully combinational),
# then sweeps products:
#   phase 1: walking ones a=1<<i, b=1<<j (bit-level wiring map)
#   phase 2: a,b in 0..127 with stride <step> (default 3 -> ~1.8k products)
# Prints every mismatch as "a b got exp" and writes all of them to
# macprobe_fails.txt next to the hex file.
# =============================================================================
if {[llength $argv] < 2} {
    puts "usage: xsdb macprobe_xsdb.tcl <pdi> <blk_macprobe.hex> \[base\] \[step\]"
    exit 1
}
set PDI  [lindex $argv 0]
set HEX  [lindex $argv 1]
set BASE [expr {[llength $argv] > 2 ? [lindex $argv 2] : 0xA4000000}]
set STEP [expr {[llength $argv] > 3 ? [lindex $argv 3] : 3}]

set R(ID) 0x00; set R(CTRL) 0x04; set R(CFG_DATA) 0x0C; set R(CFG_COUNT) 0x10
set R(IO_IN) 0x14; set R(IO_OUT) 0x18
proc wr {name v} { global BASE R; mwr -force [expr {$BASE + $R($name)}] [expr {$v & 0xFFFFFFFF}] }
proc rd {name}   { global BASE R; return [mrd -force -value [expr {$BASE + $R($name)}]] }

connect
targets -set -nocase -filter {name =~ "*Versal*"}
rst -system
after 1500
targets -set -nocase -filter {name =~ "PMC"}
puts "== programming $PDI"
device program $PDI
after 2000
targets -set -nocase -filter {name =~ "APU*"}

set id [rd ID]
if {$id != 0xEF0A0001} { puts [format "ID=0x%08x - wrong base/PDI?" $id]; exit 1 }

# load the probe bitstream
set fh [open $HEX r]; set words {}
foreach line [split [read $fh] "\n"] {
    set line [string trim $line]
    if {$line ne ""} { lappend words [expr {"0x$line"}] }
}
close $fh
wr CTRL 0x3
foreach w $words { wr CFG_DATA $w }
if {[rd CFG_COUNT] != [llength $words]} { puts "CFG_COUNT mismatch"; exit 1 }
wr IO_IN 0
wr CTRL 0x0
puts "== probe loaded ([llength $words] words), sweeping"

set ff [open [file join [file dirname $HEX] macprobe_fails.txt] w]
set errors 0; set total 0
proc probe {a b} {
    global errors total ff
    wr IO_IN [expr {($b << 9) | ($a << 2)}]
    set got [expr {([rd IO_OUT] >> 2) & 0x3FFF}]
    set exp [expr {($a * $b) & 0x3FFF}]
    incr total
    if {$got != $exp} {
        incr errors
        puts $ff [format "%d %d %04x %04x" $a $b $got $exp]
        if {$errors <= 40} { puts [format "  a=%3d b=%3d got %04x exp %04x xor %04x" $a $b $got $exp [expr {$got ^ $exp}]] }
    }
}

puts "-- walking ones"
for {set i 0} {$i < 7} {incr i} {
    for {set j 0} {$j < 7} {incr j} { probe [expr {1 << $i}] [expr {1 << $j}] }
}
puts "-- sweep stride $STEP"
for {set a 0} {$a < 128} {incr a $STEP} {
    for {set b 0} {$b < 128} {incr b $STEP} { probe $a $b }
}
close $ff
puts [format "checked %d products, %d mismatches -> macprobe_fails.txt" $total $errors]
puts [expr {$errors == 0 ? "RESULT: PASS (silicon multiplier is correct!)" : "RESULT: FAIL"}]
exit [expr {$errors != 0}]
