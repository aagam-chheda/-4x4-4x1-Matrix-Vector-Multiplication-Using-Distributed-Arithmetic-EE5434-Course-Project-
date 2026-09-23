// demo_tb.sv
//
// Presentation demo: true per-instance parameterization of
// da_matvec_mult. Instantiates the exact same RTL module three times,
// each with a DIFFERENT 4x4 matrix supplied via the A_FLAT parameter --
// no rebuild between cases, all three exist side by side in one
// compiled, elaborated simulation -- drives one example vector into
// each, and prints a clean summary: the matrix, the input vector, and
// the computed output.
//
// This is NOT a verification testbench -- correctness of this RTL is
// already exhaustively established by tb/da_matvec_tb.sv (408,425
// checks, confirmed on Verilator, Vivado, and Xcelium). This file is
// purely for display, and each case is chosen so the expected result is
// easy to check by eye without needing to trust anything:
//   - Case 1: the REAL matrix from common/matrix_a.inc (the actual
//     verified chip), with an arbitrary example vector.
//   - Case 2: a diagonal scaling matrix diag(2,3,4,5) -- y[i] should be
//     exactly scale[i]*x[i], nothing more.
//   - Case 3: an all-ones matrix -- every row sums the same input
//     vector, so all four y elements should be identical and equal to
//     sum(x).
//
// Expected values (computed independently in Python, not from this
// hardware or from dpi/golden_model.c):
//   Case 1: x=(5,-3,10,-7)   -> y=(-984,-377,-1766,954)
//   Case 2: x=(10,10,10,10)  -> y=(20,30,40,50)
//   Case 3: x=(1,2,3,4)      -> y=(10,10,10,10)

`timescale 1ns/1ps

module demo_tb;

`include "demo_data.svh"

    localparam int XW = 8;
    localparam int YW = 18;
    localparam int CLK_PERIOD = 10;

    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // Three instances of the SAME RTL module, each parameterized with a
    // different matrix -- this is the entire point of the demo.
    //
    // lint_off UNUSEDSIGNAL: busy/done/y0..y3 below are genuinely read
    // inside run_and_print(), but only through ref-passed task
    // arguments; Verilator's unused-signal analysis doesn't trace usage
    // through that indirection in this version, so it flags them as
    // unused false-positively. Confirmed these are real reads, not dead
    // code, by inspection of run_and_print's body.
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic real_start, real_busy, real_done;
    logic signed [XW-1:0] real_x0, real_x1, real_x2, real_x3;
    logic signed [YW-1:0] real_y0, real_y1, real_y2, real_y3;

    da_matvec_mult #(.A_FLAT(DEMO_MAT_REAL)) dut_real (
        .clk(clk), .rst_n(rst_n), .start(real_start),
        .x0(real_x0), .x1(real_x1), .x2(real_x2), .x3(real_x3),
        .busy(real_busy), .done(real_done),
        .y0(real_y0), .y1(real_y1), .y2(real_y2), .y3(real_y3)
    );

    logic diag_start, diag_busy, diag_done;
    logic signed [XW-1:0] diag_x0, diag_x1, diag_x2, diag_x3;
    logic signed [YW-1:0] diag_y0, diag_y1, diag_y2, diag_y3;

    da_matvec_mult #(.A_FLAT(DEMO_MAT_DIAG)) dut_diag (
        .clk(clk), .rst_n(rst_n), .start(diag_start),
        .x0(diag_x0), .x1(diag_x1), .x2(diag_x2), .x3(diag_x3),
        .busy(diag_busy), .done(diag_done),
        .y0(diag_y0), .y1(diag_y1), .y2(diag_y2), .y3(diag_y3)
    );

    logic ones_start, ones_busy, ones_done;
    logic signed [XW-1:0] ones_x0, ones_x1, ones_x2, ones_x3;
    logic signed [YW-1:0] ones_y0, ones_y1, ones_y2, ones_y3;

    da_matvec_mult #(.A_FLAT(DEMO_MAT_ONES)) dut_ones (
        .clk(clk), .rst_n(rst_n), .start(ones_start),
        .x0(ones_x0), .x1(ones_x1), .x2(ones_x2), .x3(ones_x3),
        .busy(ones_busy), .done(ones_done),
        .y0(ones_y0), .y1(ones_y1), .y2(ones_y2), .y3(ones_y3)
    );
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------
    // Pretty-print a flat 4x4 matrix, four rows of four right-aligned
    // columns.
    // ------------------------------------------------------------------
    task automatic print_matrix(input int signed mat[16]);
        for (int r = 0; r < 4; r++) begin
            $display("    %5d %5d %5d %5d", mat[r*4+0], mat[r*4+1], mat[r*4+2], mat[r*4+3]);
        end
    endtask

    // ------------------------------------------------------------------
    // Drive one instance's inputs, wait for done, print a clean summary.
    // `ref` arguments let this one task drive any of the three DUT
    // instances above (each with its own start/busy/done/x/y signals)
    // without duplicating the wait-for-done and print logic per case.
    // ------------------------------------------------------------------
    task automatic run_and_print(
        ref   logic                  inst_start,
        ref   logic                  inst_busy,
        ref   logic                  inst_done,
        ref   logic signed [XW-1:0]  inst_x0,
        ref   logic signed [XW-1:0]  inst_x1,
        ref   logic signed [XW-1:0]  inst_x2,
        ref   logic signed [XW-1:0]  inst_x3,
        ref   logic signed [YW-1:0]  inst_y0,
        ref   logic signed [YW-1:0]  inst_y1,
        ref   logic signed [YW-1:0]  inst_y2,
        ref   logic signed [YW-1:0]  inst_y3,
        input int signed              mat[16],
        input logic signed [XW-1:0]  tx0,
        input logic signed [XW-1:0]  tx1,
        input logic signed [XW-1:0]  tx2,
        input logic signed [XW-1:0]  tx3,
        input string                 label
    );
        int cyc_guard;

        $display("");
        $display("========================================");
        $display(" %s", label);
        $display("========================================");
        $display("Matrix A:");
        print_matrix(mat);
        $display("Input vector x:   [ %5d %5d %5d %5d ]", tx0, tx1, tx2, tx3);

        while (inst_busy) @(negedge clk);
        @(negedge clk);
        inst_x0 = tx0; inst_x1 = tx1; inst_x2 = tx2; inst_x3 = tx3;
        inst_start = 1'b1;
        @(negedge clk);
        inst_start = 1'b0;

        cyc_guard = 0;
        while (!inst_done) begin
            @(negedge clk);
            cyc_guard++;
            if (cyc_guard > 64) begin
                $display("TIMEOUT waiting for done");
                return;
            end
        end

        $display("Computed y = A*x: [ %5d %5d %5d %5d ]", inst_y0, inst_y1, inst_y2, inst_y3);
    endtask

    initial begin
        rst_n = 1'b0;
        real_start = 1'b0; real_x0 = '0; real_x1 = '0; real_x2 = '0; real_x3 = '0;
        diag_start = 1'b0; diag_x0 = '0; diag_x1 = '0; diag_x2 = '0; diag_x3 = '0;
        ones_start = 1'b0; ones_x0 = '0; ones_x1 = '0; ones_x2 = '0; ones_x3 = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        run_and_print(real_start, real_busy, real_done,
                       real_x0, real_x1, real_x2, real_x3,
                       real_y0, real_y1, real_y2, real_y3,
                       DEMO_MAT_REAL, 8'sd5, -8'sd3, 8'sd10, -8'sd7,
                       "Case 1: REAL hardware matrix (common/matrix_a.inc)");

        run_and_print(diag_start, diag_busy, diag_done,
                       diag_x0, diag_x1, diag_x2, diag_x3,
                       diag_y0, diag_y1, diag_y2, diag_y3,
                       DEMO_MAT_DIAG, 8'sd10, 8'sd10, 8'sd10, 8'sd10,
                       "Case 2: diagonal scaling matrix diag(2,3,4,5)");

        run_and_print(ones_start, ones_busy, ones_done,
                       ones_x0, ones_x1, ones_x2, ones_x3,
                       ones_y0, ones_y1, ones_y2, ones_y3,
                       DEMO_MAT_ONES, 8'sd1, 8'sd2, 8'sd3, 8'sd4,
                       "Case 3: all-ones matrix (every row sums x)");

        $display("");
        $display("========================================");
        $display("All three cases above used the exact same RTL module");
        $display("(da_matvec_mult), reconfigured purely via the A_FLAT");
        $display("parameter -- no rebuild between cases, no RTL edits.");
        $display("========================================");
        $finish;
    end

endmodule
