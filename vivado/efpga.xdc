# =============================================================================
# efpga.xdc - constraints for emulating the FABulous eFPGA on a Versal
#
# 1) Combinational loops are structural, not a bug
#    The switch matrices of an FPGA fabric form a routing graph with cycles. A
#    configured bitstream from nextpnr never closes one, but Vivado sees the
#    unconfigured netlist and flags every possible cycle (DRC LUTLP-1 is an
#    ERROR at write_device_image). Downgrade it - for the fabric only, the rest
#    of the design keeps the check through the timing report.
# 2) Timing inside the fabric is NOT meaningful in Vivado
#    STA sees every structural path through the routing muxes, not the routed
#    user design. Expect negative slack on paths inside */u_efpga/*; validate
#    empirically (IO_PULSE selftest) and lower EFPGA_FREQ_MHZ if it fails.
#    Paths between the AXI wrapper and the fabric boundary are real and must meet.
# =============================================================================

set_property SEVERITY {Warning} [get_drc_checks LUTLP-1]

set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets -hierarchical -filter {NAME =~ "*u_efpga_axil*/u_efpga/*"}]
