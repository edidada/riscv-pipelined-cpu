// Default testbench configuration. The CI runner generates a per-run
// config.vh into a scratch include directory that PRECEDES this file on
// the -I search path, so no command-line -P parameter overrides are
// needed (Icarus -P syntax varies between releases and shells).
`ifndef CPU_TB_CONFIG_VH
`define CPU_TB_CONFIG_VH

`define TB_PROG          "prog.hex"
`define TB_DATA          "data.hex"
`define TB_TRACE         "ref.trace"
`define TB_REFDATA       "ref.data"
`define TB_REFREGS       "ref.regs"
`define TB_FORWARDING_EN 1
`define TB_HAZARD_EN     1
`define TB_STALL_ALL_DEP 0
`define TB_CFG_NAME      "full"
`define TB_MAX_CYCLES    5000

`endif
