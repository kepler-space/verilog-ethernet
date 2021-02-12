/*

Copyright (c) 2015-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`timescale 1ns / 1ps

/*
 * 1G Ethernet MAC with RGMII interface and TX and RX FIFOs
 */
module eth_mac_1g_rgmii_fifo #
(
    parameter integer NO_BUFG = 0, // Set to 1 to avoid inserting a BUFG for the RX clock
    // target ("SIM", "GENERIC", "XILINX", "ALTERA")
    parameter TARGET = "GENERIC",
    // IODDR style ("IODDR", "IODDR2")
    // Use IODDR for Virtex-4, Virtex-5, Virtex-6, 7 Series, Ultrascale
    // Use IODDR2 for Spartan-6
    parameter IODDR_STYLE = "IODDR2",
    // Clock input style ("BUFG", "BUFR", "BUFIO", "BUFIO2")
    // Use BUFR for Virtex-5, Virtex-6, 7-series
    // Use BUFG for Ultrascale
    // Use BUFIO2 for Spartan-6
    parameter CLOCK_INPUT_STYLE = "BUFIO2",
    // Use 90 degree clock for RGMII transmit ("TRUE", "FALSE")
    parameter USE_CLK90 = "TRUE",
    parameter AXIS_DATA_WIDTH = 8,
    parameter AXIS_KEEP_ENABLE = (AXIS_DATA_WIDTH>8),
    parameter AXIS_KEEP_WIDTH = (AXIS_DATA_WIDTH/8),
    parameter ENABLE_PADDING = 1,
    parameter MIN_FRAME_LENGTH = 64,
    parameter TX_FIFO_DEPTH = 4096,
    parameter TX_FIFO_PIPELINE_OUTPUT = 2,
    parameter TX_FRAME_FIFO = 1,
    parameter TX_DROP_BAD_FRAME = TX_FRAME_FIFO,
    parameter TX_DROP_WHEN_FULL = 0,
    parameter RX_FIFO_DEPTH = 4096,
    parameter RX_FIFO_PIPELINE_OUTPUT = 2,
    parameter RX_FRAME_FIFO = 1,
    parameter RX_DROP_BAD_FRAME = RX_FRAME_FIFO,
    parameter RX_DROP_WHEN_FULL = RX_FRAME_FIFO,
    parameter EXTERNAL_RX_FIFO = 0
)
(
    input  wire                       gtx_clk,
    input  wire                       gtx_clk90,
    input  wire                       gtx_rst,
    input  wire                       logic_clk,
    input  wire                       logic_rst,

    /*
     * AXI input
     */
    input  wire [AXIS_DATA_WIDTH-1:0] tx_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0] tx_axis_tkeep,
    input  wire                       tx_axis_tvalid,
    output wire                       tx_axis_tready,
    input  wire                       tx_axis_tlast,
    input  wire                       tx_axis_tuser,

    /*
     * AXI output
     */
    output wire [AXIS_DATA_WIDTH-1:0] rx_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0] rx_axis_tkeep,
    output wire                       rx_axis_tvalid,
    input  wire                       rx_axis_tready,
    output wire                       rx_axis_tlast,
    output wire                       rx_axis_tuser,

    /*
     * RGMII interface
     */
    input  wire                       rgmii_rx_clk,
    input  wire [3:0]                 rgmii_rxd,
    input  wire                       rgmii_rx_ctl,
    output wire                       rgmii_tx_clk,
    output wire [3:0]                 rgmii_txd,
    output wire                       rgmii_tx_ctl,

    /*
     * Status
     */
    output wire                       tx_error_underflow,
    output wire                       tx_fifo_overflow,
    output wire                       tx_fifo_bad_frame,
    output wire                       tx_fifo_good_frame,
    output wire                       rx_error_bad_frame,
    output wire                       rx_error_bad_fcs,
    output wire                       rx_fifo_overflow,
    output wire                       rx_fifo_bad_frame,
    output wire                       rx_fifo_good_frame,
    output wire [1:0]                 speed,

    /*
     * Configuration
     */
    input  wire [7:0]                 ifg_delay,

    // External RX FIFO Interfaces
    output wire                       ext_rx_fifo_clk,
    output reg                        ext_rx_fifo_rst,

    output wire [AXIS_DATA_WIDTH-1:0] ext_rx_fifo_out_tdata,
    output wire                       ext_rx_fifo_out_tvalid,
    input  wire                       ext_rx_fifo_out_tready, // TODO: this is ignored
    output wire                       ext_rx_fifo_out_tlast,
    output wire                       ext_rx_fifo_out_tuser,

    input  wire [AXIS_DATA_WIDTH-1:0] ext_rx_fifo_in_tdata,
    input  wire                       ext_rx_fifo_in_tvalid,
    output wire                       ext_rx_fifo_in_tready,
    input  wire                       ext_rx_fifo_in_tlast,
    input  wire                       ext_rx_fifo_in_tuser
);

wire tx_clk;
wire rx_clk;
wire tx_rst;
wire rx_rst;

wire [7:0]  tx_fifo_axis_tdata;
wire        tx_fifo_axis_tvalid;
wire        tx_fifo_axis_tready;
wire        tx_fifo_axis_tlast;
wire        tx_fifo_axis_tuser;

wire [7:0]  rx_fifo_axis_tdata;
wire        rx_fifo_axis_tvalid;
wire        rx_fifo_axis_tlast;
wire        rx_fifo_axis_tuser;

// synchronize MAC status signals into logic clock domain
wire tx_error_underflow_int;

reg [0:0] tx_sync_reg_1 = 1'b0;
reg [0:0] tx_sync_reg_2 = 1'b0;
reg [0:0] tx_sync_reg_3 = 1'b0;
reg [0:0] tx_sync_reg_4 = 1'b0;

assign tx_error_underflow = tx_sync_reg_3[0] ^ tx_sync_reg_4[0];

always @(posedge tx_clk or posedge tx_rst) begin
    if (tx_rst) begin
        tx_sync_reg_1 <= 1'b0;
    end else begin
        tx_sync_reg_1 <= tx_sync_reg_1 ^ {tx_error_underflow_int};
    end
end

always @(posedge logic_clk or posedge logic_rst) begin
    if (logic_rst) begin
        tx_sync_reg_2 <= 1'b0;
        tx_sync_reg_3 <= 1'b0;
        tx_sync_reg_4 <= 1'b0;
    end else begin
        tx_sync_reg_2 <= tx_sync_reg_1;
        tx_sync_reg_3 <= tx_sync_reg_2;
        tx_sync_reg_4 <= tx_sync_reg_3;
    end
end

wire rx_error_bad_frame_int;
wire rx_error_bad_fcs_int;

reg [1:0] rx_sync_reg_1 = 2'd0;
reg [1:0] rx_sync_reg_2 = 2'd0;
reg [1:0] rx_sync_reg_3 = 2'd0;
reg [1:0] rx_sync_reg_4 = 2'd0;

assign rx_error_bad_frame = rx_sync_reg_3[0] ^ rx_sync_reg_4[0];
assign rx_error_bad_fcs = rx_sync_reg_3[1] ^ rx_sync_reg_4[1];

always @(posedge rx_clk or posedge rx_rst) begin
    if (rx_rst) begin
        rx_sync_reg_1 <= 2'd0;
    end else begin
        rx_sync_reg_1 <= rx_sync_reg_1 ^ {rx_error_bad_fcs_int, rx_error_bad_frame_int};
    end
end

always @(posedge logic_clk or posedge logic_rst) begin
    if (logic_rst) begin
        rx_sync_reg_2 <= 2'd0;
        rx_sync_reg_3 <= 2'd0;
        rx_sync_reg_4 <= 2'd0;
    end else begin
        rx_sync_reg_2 <= rx_sync_reg_1;
        rx_sync_reg_3 <= rx_sync_reg_2;
        rx_sync_reg_4 <= rx_sync_reg_3;
    end
end

wire [1:0] speed_int;

xclock_vec_on_change #(
    .WIDTH  ( 2 )
) sync_speed_inst (
    .in_clk             ( gtx_clk   ),
    .in_rst             ( gtx_rst   ),
    .in_vec             ( speed_int ),
    .out_clk            ( logic_clk ),
    .out_rst            (           ),
    .out_vec            ( speed     ),
    .out_changed_stb    (           )
);

wire logic_rst_rx_clk;

eth_mac_1g_rgmii #(
    .NO_BUFG(NO_BUFG),
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .CLOCK_INPUT_STYLE(CLOCK_INPUT_STYLE),
    .USE_CLK90(USE_CLK90),
    .ENABLE_PADDING(ENABLE_PADDING),
    .MIN_FRAME_LENGTH(MIN_FRAME_LENGTH)
)
eth_mac_1g_rgmii_inst (
    .gtx_clk(gtx_clk),
    .gtx_clk90(gtx_clk90),
    .gtx_rst(gtx_rst),
    .tx_clk(tx_clk),
    .tx_rst(tx_rst),
    .rx_clk(rx_clk),
    .rx_rst(rx_rst),
    .tx_axis_tdata(tx_fifo_axis_tdata),
    .tx_axis_tvalid(tx_fifo_axis_tvalid),
    .tx_axis_tready(tx_fifo_axis_tready),
    .tx_axis_tlast(tx_fifo_axis_tlast),
    .tx_axis_tuser(tx_fifo_axis_tuser),
    .rx_axis_tdata(rx_fifo_axis_tdata),
    .rx_axis_tvalid(rx_fifo_axis_tvalid),
    .rx_axis_tlast(rx_fifo_axis_tlast),
    .rx_axis_tuser(rx_fifo_axis_tuser),
    .rgmii_rx_clk(rgmii_rx_clk),
    .rgmii_rxd(rgmii_rxd),
    .rgmii_rx_ctl(rgmii_rx_ctl),
    .rgmii_tx_clk(rgmii_tx_clk),
    .rgmii_txd(rgmii_txd),
    .rgmii_tx_ctl(rgmii_tx_ctl),
    .tx_error_underflow(tx_error_underflow_int),
    .rx_error_bad_frame(rx_error_bad_frame_int),
    .rx_error_bad_fcs(rx_error_bad_fcs_int),
    .speed(speed_int),
    .ifg_delay(ifg_delay)
);

axis_async_fifo_adapter #(
    .DEPTH(TX_FIFO_DEPTH),
    .S_DATA_WIDTH(AXIS_DATA_WIDTH),
    .S_KEEP_ENABLE(AXIS_KEEP_ENABLE),
    .S_KEEP_WIDTH(AXIS_KEEP_WIDTH),
    .M_DATA_WIDTH(8),
    .M_KEEP_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(1),
    .USER_WIDTH(1),
    .PIPELINE_OUTPUT(TX_FIFO_PIPELINE_OUTPUT),
    .FRAME_FIFO(TX_FRAME_FIFO),
    .USER_BAD_FRAME_VALUE(1'b1),
    .USER_BAD_FRAME_MASK(1'b1),
    .DROP_BAD_FRAME(TX_DROP_BAD_FRAME),
    .DROP_WHEN_FULL(TX_DROP_WHEN_FULL)
)
tx_fifo (
    // AXI input
    .s_clk(logic_clk),
    .s_rst(logic_rst),
    .s_axis_tdata(tx_axis_tdata),
    .s_axis_tkeep(tx_axis_tkeep),
    .s_axis_tvalid(tx_axis_tvalid),
    .s_axis_tready(tx_axis_tready),
    .s_axis_tlast(tx_axis_tlast),
    .s_axis_tid(0),
    .s_axis_tdest(0),
    .s_axis_tuser(tx_axis_tuser),
    // AXI output
    .m_clk(tx_clk),
    .m_rst(tx_rst),
    .m_axis_tdata(tx_fifo_axis_tdata),
    .m_axis_tkeep(),
    .m_axis_tvalid(tx_fifo_axis_tvalid),
    .m_axis_tready(tx_fifo_axis_tready),
    .m_axis_tlast(tx_fifo_axis_tlast),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(tx_fifo_axis_tuser),
    // Status
    .s_status_overflow(tx_fifo_overflow),
    .s_status_bad_frame(tx_fifo_bad_frame),
    .s_status_good_frame(tx_fifo_good_frame),
    .m_status_overflow(),
    .m_status_bad_frame(),
    .m_status_good_frame()
);

generate
    if (EXTERNAL_RX_FIFO) begin
        assign ext_rx_fifo_clk = rx_clk;

        xclock_rst #(
            .FF_CASCADE(2)
        ) xclock_logic_rst_rx_clk (
            .tx_clk (logic_clk       ),
            .rst_in (logic_rst       ),
            .rx_clk (rx_clk          ),
            .rst_out(logic_rst_rx_clk)
        );

        always @(posedge rx_clk) begin
            ext_rx_fifo_rst <= rx_rst | logic_rst_rx_clk;
        end

        assign ext_rx_fifo_out_tdata  = rx_fifo_axis_tdata;
        assign ext_rx_fifo_out_tvalid = rx_fifo_axis_tvalid;
        assign ext_rx_fifo_out_tlast  = rx_fifo_axis_tlast;
        assign ext_rx_fifo_out_tuser  = rx_fifo_axis_tuser;

        axis_async_fifo_adapter #(
            .DEPTH(RX_FIFO_DEPTH),
            .S_DATA_WIDTH(8),
            .S_KEEP_ENABLE(0),
            .M_DATA_WIDTH(AXIS_DATA_WIDTH),
            .M_KEEP_ENABLE(AXIS_KEEP_ENABLE),
            .M_KEEP_WIDTH(AXIS_KEEP_WIDTH),
            .ID_ENABLE(0),
            .DEST_ENABLE(0),
            .USER_ENABLE(1),
            .USER_WIDTH(1),
            .PIPELINE_OUTPUT(RX_FIFO_PIPELINE_OUTPUT),
            .FRAME_FIFO(RX_FRAME_FIFO),
            .USER_BAD_FRAME_VALUE(1'b1),
            .USER_BAD_FRAME_MASK(1'b1),
            .DROP_BAD_FRAME(RX_DROP_BAD_FRAME),
            .DROP_WHEN_FULL(RX_DROP_WHEN_FULL)
        )
        rx_fifo (
            // AXI input
            .s_clk(rx_clk),
            .s_rst(rx_rst),
            .s_axis_tdata(ext_rx_fifo_in_tdata),
            .s_axis_tkeep(0),
            .s_axis_tvalid(ext_rx_fifo_in_tvalid),
            .s_axis_tready(ext_rx_fifo_in_tready),
            .s_axis_tlast(ext_rx_fifo_in_tlast),
            .s_axis_tid(0),
            .s_axis_tdest(0),
            .s_axis_tuser(ext_rx_fifo_in_tuser),
            // AXI output
            .m_clk(logic_clk),
            .m_rst(logic_rst),
            .m_axis_tdata(rx_axis_tdata),
            .m_axis_tkeep(rx_axis_tkeep),
            .m_axis_tvalid(rx_axis_tvalid),
            .m_axis_tready(rx_axis_tready),
            .m_axis_tlast(rx_axis_tlast),
            .m_axis_tid(),
            .m_axis_tdest(),
            .m_axis_tuser(rx_axis_tuser),
            // Status
            .s_status_overflow(),
            .s_status_bad_frame(),
            .s_status_good_frame(),
            .m_status_overflow(rx_fifo_overflow),
            .m_status_bad_frame(rx_fifo_bad_frame),
            .m_status_good_frame(rx_fifo_good_frame)
        );
    end else begin
        axis_async_fifo_adapter #(
            .DEPTH(RX_FIFO_DEPTH),
            .S_DATA_WIDTH(8),
            .S_KEEP_ENABLE(0),
            .M_DATA_WIDTH(AXIS_DATA_WIDTH),
            .M_KEEP_ENABLE(AXIS_KEEP_ENABLE),
            .M_KEEP_WIDTH(AXIS_KEEP_WIDTH),
            .ID_ENABLE(0),
            .DEST_ENABLE(0),
            .USER_ENABLE(1),
            .USER_WIDTH(1),
            .PIPELINE_OUTPUT(RX_FIFO_PIPELINE_OUTPUT),
            .FRAME_FIFO(RX_FRAME_FIFO),
            .USER_BAD_FRAME_VALUE(1'b1),
            .USER_BAD_FRAME_MASK(1'b1),
            .DROP_BAD_FRAME(RX_DROP_BAD_FRAME),
            .DROP_WHEN_FULL(RX_DROP_WHEN_FULL)
        )
        rx_fifo (
            // AXI input
            .s_clk(rx_clk),
            .s_rst(rx_rst),
            .s_axis_tdata(rx_fifo_axis_tdata),
            .s_axis_tkeep(0),
            .s_axis_tvalid(rx_fifo_axis_tvalid),
            .s_axis_tready(),
            .s_axis_tlast(rx_fifo_axis_tlast),
            .s_axis_tid(0),
            .s_axis_tdest(0),
            .s_axis_tuser(rx_fifo_axis_tuser),
            // AXI output
            .m_clk(logic_clk),
            .m_rst(logic_rst),
            .m_axis_tdata(rx_axis_tdata),
            .m_axis_tkeep(rx_axis_tkeep),
            .m_axis_tvalid(rx_axis_tvalid),
            .m_axis_tready(rx_axis_tready),
            .m_axis_tlast(rx_axis_tlast),
            .m_axis_tid(),
            .m_axis_tdest(),
            .m_axis_tuser(rx_axis_tuser),
            // Status
            .s_status_overflow(),
            .s_status_bad_frame(),
            .s_status_good_frame(),
            .m_status_overflow(rx_fifo_overflow),
            .m_status_bad_frame(rx_fifo_bad_frame),
            .m_status_good_frame(rx_fifo_good_frame)
        );

        // Tie off unused outputs
        assign ext_rx_fifo_clk          = 1'b0;
        assign ext_rx_fifo_out_tdata    = {AXIS_DATA_WIDTH{1'bX}};
        assign ext_rx_fifo_out_tvalid   = 1'b0;
        assign ext_rx_fifo_out_tlast    = 1'b0;
        assign ext_rx_fifo_out_tuser    = 1'b0;
        assign ext_rx_fifo_in_tready    = 1'b0;
        always @(posedge rx_clk) begin
            ext_rx_fifo_rst <= 1'b0;
        end

    end
endgenerate

endmodule
