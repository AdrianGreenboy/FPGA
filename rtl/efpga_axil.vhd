-- =============================================================================
-- efpga_axil : AXI4-Lite host interface for the FABulous eFPGA (efpga_v0)
--   VHDL (analyses clean as VHDL-93 and VHDL-2008, added to Vivado as plain VHDL so
--   it can be used as a block-design module reference); single clock domain
--   (aclk = fabric CLK = config clock)
--
-- Register map (byte offsets, 32-bit registers)
--   0x00 ID        RO  0xEF0A_0001  ("eFPGA", fabric revision 1)
--   0x04 CTRL      RW  [0] CFG_MODE  1 = isolate fabric (inputs forced 0, outputs
--                                        masked to 0) - set during (re)configuration
--                      [1] CFG_RESET write 1 = pulse ConfigFSM reset (self-clearing),
--                                        also clears CFG_COUNT
--                      [2] IN_SEL    0 = fabric inputs from IO_IN register
--                                    1 = fabric inputs from external pins (pin_i)
--   0x08 STATUS    RO  [0] CFG_BUSY  [1] CFG_MODE  [2] IN_SEL  [3] PULSE_BUSY
--   0x0C CFG_DATA  WO  one bitstream word (MSB-first as in the .bin). The write
--                      response is held until the SelfWrite sequence is finished,
--                      so software can stream words back-to-back without polling.
--   0x10 CFG_COUNT RO  words written since the last CFG_RESET
--   0x14 IO_IN     RW  [15:0] fabric inputs  (O_top)
--   0x18 IO_OUT    RO  [15:0] fabric outputs (I_top), masked while CFG_MODE=1
--   0x1C IO_OE     RO  [15:0] fabric output enables (T_top, 1 = fabric drives pin)
--   0x20 SCRATCH   RW
--   0x24 CYCLES    RO  free-running aclk counter (lets SW measure the fabric clock)
--   0x28 IO_PULSE  RW  write: [15:0] MASK, [31:16] COUNT -> fabric inputs are
--                      IO_IN | MASK for exactly COUNT rising edges of aclk, then
--                      back to IO_IN. Ignored while busy or in CFG_MODE.
--                      read : [15:0] MASK, [31:16] remaining count
--                      Gives cycle-exact stimulus from software (e.g. "enable the
--                      design for exactly N clocks"), so silicon results can be
--                      compared bit-exactly against a golden model.
--
-- SelfWrite timing (ConfigFSM.v): data stable >= 2 clk, 1-clk strobe, then >= 2 clk
-- quiet, because long_frame_strobe is 2 clk wide and frame_address_register must
-- not change underneath it. One word therefore takes 5 aclk cycles.
--
-- Decode is a plain case statement on the registered address - no indexed
-- functions/constant arrays (Vivado 2025.2.1 mis-synthesis lesson).
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity efpga_axil is
    generic (
        G_NUM_IO : positive := 16
    );
    port (
        aclk          : in  std_logic;
        aresetn       : in  std_logic;
        -- AXI4-Lite slave
        s_axi_awaddr  : in  std_logic_vector(7 downto 0);
        s_axi_awprot  : in  std_logic_vector(2 downto 0);
        s_axi_awvalid : in  std_logic;
        s_axi_awready : out std_logic;
        s_axi_wdata   : in  std_logic_vector(31 downto 0);
        s_axi_wstrb   : in  std_logic_vector(3 downto 0);
        s_axi_wvalid  : in  std_logic;
        s_axi_wready  : out std_logic;
        s_axi_bresp   : out std_logic_vector(1 downto 0);
        s_axi_bvalid  : out std_logic;
        s_axi_bready  : in  std_logic;
        s_axi_araddr  : in  std_logic_vector(7 downto 0);
        s_axi_arprot  : in  std_logic_vector(2 downto 0);
        s_axi_arvalid : in  std_logic;
        s_axi_arready : out std_logic;
        s_axi_rdata   : out std_logic_vector(31 downto 0);
        s_axi_rresp   : out std_logic_vector(1 downto 0);
        s_axi_rvalid  : out std_logic;
        s_axi_rready  : in  std_logic;
        -- optional external pins (PMOD / LEDs / your own IP cores)
        pin_i         : in  std_logic_vector(G_NUM_IO - 1 downto 0);
        pin_o         : out std_logic_vector(G_NUM_IO - 1 downto 0);
        pin_oe        : out std_logic_vector(G_NUM_IO - 1 downto 0)
    );
    -- block-design module reference: bind clock/reset to the s_axi interface
    attribute X_INTERFACE_INFO      : string;
    attribute X_INTERFACE_PARAMETER : string;
    attribute X_INTERFACE_INFO      of aclk    : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
    attribute X_INTERFACE_PARAMETER of aclk    : signal is "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn";
    attribute X_INTERFACE_INFO      of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
    attribute X_INTERFACE_PARAMETER of aresetn : signal is "POLARITY ACTIVE_LOW";
end entity efpga_axil;

architecture rtl of efpga_axil is

    component eFPGA_top is
        port (
            A_config_C      : out std_logic_vector(31 downto 0);
            B_config_C      : out std_logic_vector(31 downto 0);
            Config_accessC  : out std_logic_vector(31 downto 0);
            I_top           : out std_logic_vector(15 downto 0);
            O_top           : in  std_logic_vector(15 downto 0);
            T_top           : out std_logic_vector(15 downto 0);
            CLK             : in  std_logic;
            resetn          : in  std_logic;
            SelfWriteStrobe : in  std_logic;
            SelfWriteData   : in  std_logic_vector(31 downto 0);
            Rx              : in  std_logic;
            ComActive       : out std_logic;
            ReceiveLED      : out std_logic;
            s_clk           : in  std_logic;
            s_data          : in  std_logic
        );
    end component;

    constant C_ID : std_logic_vector(31 downto 0) := x"EF0A0001";

    -- AXI write channel
    type wr_state_t is (WR_IDLE, WR_CFG, WR_RESP);
    signal wr_state   : wr_state_t := WR_IDLE;
    signal awready_r  : std_logic := '0';
    signal wready_r   : std_logic := '0';
    signal bvalid_r   : std_logic := '0';
    signal aw_addr    : std_logic_vector(7 downto 0) := (others => '0');
    signal aw_seen    : std_logic := '0';
    signal w_data     : std_logic_vector(31 downto 0) := (others => '0');
    signal w_strb     : std_logic_vector(3 downto 0) := (others => '0');
    signal w_seen     : std_logic := '0';

    -- AXI read channel
    signal arready_r  : std_logic := '0';
    signal rvalid_r   : std_logic := '0';
    signal rdata_r    : std_logic_vector(31 downto 0) := (others => '0');

    -- registers
    signal cfg_mode   : std_logic := '1';   -- isolated after reset until SW releases it
    signal in_sel     : std_logic := '0';
    signal io_in_r    : std_logic_vector(15 downto 0) := (others => '0');
    signal scratch_r  : std_logic_vector(31 downto 0) := (others => '0');
    signal cfg_count  : unsigned(31 downto 0) := (others => '0');
    signal cycles     : unsigned(31 downto 0) := (others => '0');
    signal pulse_cnt  : unsigned(15 downto 0) := (others => '0');
    signal pulse_mask : std_logic_vector(15 downto 0) := (others => '0');
    signal pulse_busy : std_logic;

    -- config sequencer
    signal seq_cnt    : unsigned(2 downto 0) := (others => '0');
    signal cfg_busy   : std_logic := '0';
    signal sw_strobe  : std_logic := '0';
    signal sw_data    : std_logic_vector(31 downto 0) := (others => '0');
    signal rst_cnt    : unsigned(2 downto 0) := (others => '0');
    signal fab_resetn : std_logic := '0';

    -- fabric
    signal fab_o_top  : std_logic_vector(15 downto 0);
    signal fab_i_top  : std_logic_vector(15 downto 0);
    signal fab_t_top  : std_logic_vector(15 downto 0);
    signal fab_i_q    : std_logic_vector(15 downto 0) := (others => '0');
    signal fab_t_q    : std_logic_vector(15 downto 0) := (others => '0');
    signal pin_i_q    : std_logic_vector(15 downto 0) := (others => '0');

begin

    assert G_NUM_IO = 16
        report "efpga_v0 has exactly 16 IO_1_bidirectional bels (W_IO, 8 rows x 2)"
        severity failure;

    -- -------------------------------------------------------------------------
    -- AXI write path: accept AW and W independently, act when both are present
    -- -------------------------------------------------------------------------
    s_axi_awready <= awready_r;
    s_axi_wready  <= wready_r;
    s_axi_bvalid  <= bvalid_r;
    s_axi_bresp   <= "00";

    p_write : process (aclk)
        variable v_addr : std_logic_vector(7 downto 0);
    begin
        if rising_edge(aclk) then
            awready_r <= '0';
            wready_r  <= '0';

            if aresetn = '0' then
                wr_state  <= WR_IDLE;
                aw_seen   <= '0';
                w_seen    <= '0';
                bvalid_r  <= '0';
                cfg_mode  <= '1';
                in_sel    <= '0';
                io_in_r   <= (others => '0');
                scratch_r <= (others => '0');
                cfg_count <= (others => '0');
                seq_cnt   <= (others => '0');
                cfg_busy  <= '0';
                sw_strobe <= '0';
                rst_cnt   <= (others => '1');  -- ConfigFSM reset after AXI reset
                pulse_cnt <= (others => '0');
                pulse_mask <= (others => '0');
            else
                if pulse_cnt /= 0 then
                    pulse_cnt <= pulse_cnt - 1;
                end if;

                -- ConfigFSM reset pulse generator (8 clk low)
                if rst_cnt /= 0 then
                    rst_cnt <= rst_cnt - 1;
                end if;

                case wr_state is
                    when WR_IDLE =>
                        if aw_seen = '0' and s_axi_awvalid = '1' and awready_r = '0' then
                            awready_r <= '1';
                            aw_addr   <= s_axi_awaddr;
                            aw_seen   <= '1';
                        end if;
                        if w_seen = '0' and s_axi_wvalid = '1' and wready_r = '0' then
                            wready_r <= '1';
                            w_data   <= s_axi_wdata;
                            w_strb   <= s_axi_wstrb;
                            w_seen   <= '1';
                        end if;

                        if aw_seen = '1' and w_seen = '1' then
                            aw_seen  <= '0';
                            w_seen   <= '0';
                            v_addr   := aw_addr(7 downto 2) & "00";
                            wr_state <= WR_RESP;
                            case v_addr is
                                when x"04" =>
                                    if w_strb(0) = '1' then
                                        cfg_mode <= w_data(0);
                                        in_sel   <= w_data(2);
                                        if w_data(1) = '1' then
                                            rst_cnt   <= (others => '1');
                                            cfg_count <= (others => '0');
                                        end if;
                                    end if;
                                when x"0C" =>
                                    -- bitstream word: start the SelfWrite sequence
                                    sw_data  <= w_data;
                                    seq_cnt  <= (others => '0');
                                    cfg_busy <= '1';
                                    wr_state <= WR_CFG;
                                when x"14" =>
                                    if w_strb(0) = '1' then io_in_r(7 downto 0)  <= w_data(7 downto 0);  end if;
                                    if w_strb(1) = '1' then io_in_r(15 downto 8) <= w_data(15 downto 8); end if;
                                when x"28" =>
                                    if pulse_cnt = 0 and cfg_mode = '0' and w_strb = "1111" then
                                        pulse_mask <= w_data(15 downto 0);
                                        pulse_cnt  <= unsigned(w_data(31 downto 16));
                                    end if;
                                when x"20" =>
                                    for b in 0 to 3 loop
                                        if w_strb(b) = '1' then
                                            scratch_r(8 * b + 7 downto 8 * b) <= w_data(8 * b + 7 downto 8 * b);
                                        end if;
                                    end loop;
                                when others =>
                                    null;   -- RO / unmapped: ignored, OKAY response
                            end case;
                        end if;

                    when WR_CFG =>
                        -- cycle: 0,1 data settle | 2 strobe | 3,4 quiet | done
                        seq_cnt <= seq_cnt + 1;
                        if seq_cnt = 2 then
                            sw_strobe <= '1';
                        else
                            sw_strobe <= '0';
                        end if;
                        if seq_cnt = 4 then
                            cfg_busy  <= '0';
                            cfg_count <= cfg_count + 1;
                            wr_state  <= WR_RESP;
                        end if;

                    when WR_RESP =>
                        if bvalid_r = '0' then
                            bvalid_r <= '1';
                        elsif s_axi_bready = '1' then
                            bvalid_r <= '0';
                            wr_state <= WR_IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process p_write;

    -- registered: drives the asynchronous reset of ConfigFSM, must be glitch-free
    p_fab_rst : process (aclk)
    begin
        if rising_edge(aclk) then
            if rst_cnt = 0 then
                fab_resetn <= '1';
            else
                fab_resetn <= '0';
            end if;
        end if;
    end process p_fab_rst;

    -- -------------------------------------------------------------------------
    -- AXI read path
    -- -------------------------------------------------------------------------
    s_axi_arready <= arready_r;
    s_axi_rvalid  <= rvalid_r;
    s_axi_rdata   <= rdata_r;
    s_axi_rresp   <= "00";

    p_read : process (aclk)
        variable v_addr : std_logic_vector(7 downto 0);
    begin
        if rising_edge(aclk) then
            arready_r <= '0';
            if aresetn = '0' then
                rvalid_r <= '0';
                rdata_r  <= (others => '0');
            else
                if rvalid_r = '0' and s_axi_arvalid = '1' and arready_r = '0' then
                    arready_r <= '1';
                    rvalid_r  <= '1';
                    v_addr    := s_axi_araddr(7 downto 2) & "00";
                    case v_addr is
                        when x"00"  => rdata_r <= C_ID;
                        when x"04"  => rdata_r <= (0 => cfg_mode, 2 => in_sel, others => '0');
                        when x"08"  => rdata_r <= (0 => cfg_busy, 1 => cfg_mode, 2 => in_sel,
                                                   3 => pulse_busy, others => '0');
                        when x"10"  => rdata_r <= std_logic_vector(cfg_count);
                        when x"14"  => rdata_r <= x"0000" & io_in_r;
                        when x"18"  => rdata_r <= x"0000" & fab_i_q;
                        when x"1C"  => rdata_r <= x"0000" & fab_t_q;
                        when x"20"  => rdata_r <= scratch_r;
                        when x"24"  => rdata_r <= std_logic_vector(cycles);
                        when x"28"  => rdata_r <= std_logic_vector(pulse_cnt) & pulse_mask;
                        when others => rdata_r <= (others => '0');
                    end case;
                elsif rvalid_r = '1' and s_axi_rready = '1' then
                    rvalid_r <= '0';
                end if;
            end if;
        end if;
    end process p_read;

    -- -------------------------------------------------------------------------
    -- Fabric IO isolation + sampling
    -- -------------------------------------------------------------------------
    p_io : process (aclk)
    begin
        if rising_edge(aclk) then
            cycles  <= cycles + 1;
            pin_i_q <= pin_i;               -- external pins: 1 FF (same clock domain
                                            -- assumed; add a 2-FF sync for async pins)
            if cfg_mode = '1' then
                fab_i_q <= (others => '0');
                fab_t_q <= (others => '0');
            else
                fab_i_q <= fab_i_top;
                fab_t_q <= fab_t_top;
            end if;
        end if;
    end process p_io;

    pulse_busy <= '1' when pulse_cnt /= 0 else '0';

    fab_o_top <= (others => '0')        when cfg_mode = '1'   else
                 pin_i_q                 when in_sel = '1'     else
                 io_in_r or pulse_mask   when pulse_busy = '1' else
                 io_in_r;

    pin_o  <= fab_i_q;
    pin_oe <= fab_t_q;

    -- -------------------------------------------------------------------------
    -- The fabric (generated by FABulous, Verilog)
    -- -------------------------------------------------------------------------
    u_efpga : eFPGA_top
        port map (
            A_config_C      => open,
            B_config_C      => open,
            Config_accessC  => open,
            I_top           => fab_i_top,
            O_top           => fab_o_top,
            T_top           => fab_t_top,
            CLK             => aclk,
            resetn          => fab_resetn,
            SelfWriteStrobe => sw_strobe,
            SelfWriteData   => sw_data,
            Rx              => '1',
            ComActive       => open,
            ReceiveLED      => open,
            s_clk           => '0',
            s_data          => '0'
        );

end architecture rtl;
