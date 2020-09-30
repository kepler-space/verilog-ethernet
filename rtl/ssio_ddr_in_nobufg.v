/*

Kepler: This is copied from ssio_ddr_in.v, it is a modified version that does not insert BUFGs
        This is required for our hacks in rgmii_phy_if

Copyright (c) 2016-2018 Alex Forencich

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
 * Generic source synchronous DDR input
 */
module ssio_ddr_in_nobufg #
(
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
    // Width of register in bits
    parameter WIDTH = 1
)
(
    (* clock_buffer_type = "none" *) input  wire             input_clk,

    input  wire [WIDTH-1:0] input_d,

    (* clock_buffer_type = "none" *) output wire             output_clk,

    output wire [WIDTH-1:0] output_q1,
    output wire [WIDTH-1:0] output_q2
);

(* clock_buffer_type = "none" *) wire clk_int;
(* clock_buffer_type = "none" *) wire clk_io;

// pass through RX clock to input buffers
assign clk_io = input_clk;

// pass through RX clock to logic
assign clk_int = input_clk;
assign output_clk = clk_int;

iddr #(
    .TARGET(TARGET),
    .IODDR_STYLE(IODDR_STYLE),
    .WIDTH(WIDTH)
)
data_iddr_inst (
    .clk(clk_io),
    .d(input_d),
    .q1(output_q1),
    .q2(output_q2)
);

endmodule
