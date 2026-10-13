# pdn_m2_density_blk.tcl : Metal2 density straps + placement blockages under them.
#
# Same straps as pdn_m2_density.tcl, plus a placement blockage over every
# Metal2 strap (0.5 um guard each side), created right after pdngen.
#
# Why: the straps are vertical Metal2, i.e. on the first routing layer. A std
# cell placed under a strap can have its Metal1 pins covered, so every pin
# access via (Metal1 -> Metal2 landing pad) shorts to VPWR/VGND. Detailed
# routing cannot repair that (DSP at the NLP size 372.48 x 488.04: 14 Metal2
# shorts, only FrameData nets vs. VPWR/VGND, all at strap x positions, stuck
# from iteration 5 to the 900 s timeout). In the exploration step the same
# straps passed by luck of placement. Blocking the strap footprint costs
# ~4.4 um of placement width per 50 um strap pitch (~9 %).
#
# The blockages are added from a trace on pdngen because the straps only
# exist after pdngen (this file is sourced before it, as PDN_CFG). Global and
# detailed placement honour odb placement blockages.
source [file join [file dirname [info script]] pdn_m2_density.tcl]

proc ::m2_strap_blockages {args} {
    set block [ord::get_db_block]
    set dbu [$block getDbUnitsPerMicron]
    set guard [expr {int(0.5 * $dbu)}]
    set n 0
    foreach net [$block getNets] {
        if {![$net isSpecial]} { continue }
        foreach sw [$net getSWires] {
            foreach w [$sw getWires] {
                if {[$w isVia]} { continue }
                set l [$w getTechLayer]
                if {$l eq "NULL" || [$l getName] ne "Metal2"} { continue }
                # straps only: long vertical wires, not via landing pads
                if {[expr {[$w yMax] - [$w yMin]}] < 10 * $dbu} { continue }
                odb::dbBlockage_create $block \
                    [expr {[$w xMin] - $guard}] [$w yMin] \
                    [expr {[$w xMax] + $guard}] [$w yMax]
                incr n
            }
        }
    }
    puts "\[INFO\] pdn_m2_density_blk: $n placement blockages over Metal2 straps (guard 0.5 um)"
}
trace add execution pdngen leave ::m2_strap_blockages
