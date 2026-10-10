// Techmap: yosys generic D-latch -> IHP SG13G2 high-enable D-latch.
// Used by the FABulous structural timing model flow (timing_model command):
// the fabric's config latches infer $_DLATCH_P_ during tile synthesis and
// must map to a real PDK cell before OpenSTA can time the switch matrices.
module \$_DLATCH_P_ (input E, input D, output Q);
    sg13g2_dlhq_1 _TECHMAP_DLATCH_P (
        .GATE (E),
        .D    (D),
        .Q    (Q)
    );
endmodule
