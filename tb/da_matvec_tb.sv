// da_matvec_tb.sv
//
// Self-checking testbench + scoreboard for da_matvec_mult.
//   - DPI-C golden model (dpi/golden_model.c) provides expected results.
//   - Directed tests cover all-zero, all-(-128), all-(+127), a hand-picked
//     mixed-sign vector, and a near-worst-case-magnitude vector.
//   - 5000 random signed 8-bit vectors, biased toward the value extremes,
//     are checked against the golden model.
//   - A lightweight cycle/coverage tracker confirms all 8 shift cycles and
//     both the subtract (cycle 0) and add (cycles 1-7) control paths of the
//     DUT are exercised at least once, without depending on simulator-
//     specific coverage tooling (works identically under Verilator and
//     Vivado xsim).
//   - Exits with a nonzero status on any scoreboard mismatch (via $fatal),
//     suitable for CI/regression use.

`timescale 1ns/1ps

import "DPI-C" function void golden_matvec(
    input  byte x0,
    input  byte x1,
    input  byte x2,
    input  byte x3,
    output int  y0,
    output int  y1,
    output int  y2,
    output int  y3
);

module da_matvec_tb;

    localparam int XW = 8;
    localparam int YW = 18;
    localparam int CLK_PERIOD = 10;
    localparam int NUM_RANDOM = 5000;

    logic                 clk;
    logic                 rst_n;
    logic                 start;
    logic signed [XW-1:0] x0, x1, x2, x3;
    logic                 busy;
    logic                 done;
    logic signed [YW-1:0] y0, y1, y2, y3;

    da_matvec_mult #(
        .N  (4),
        .XW (XW),
        .YW (YW),
        .RW (10)
    ) dut (
        .clk   (clk),
        .rst_n (rst_n),
        .start (start),
        .x0    (x0),
        .x1    (x1),
        .x2    (x2),
        .x3    (x3),
        .busy  (busy),
        .done  (done),
        .y0    (y0),
        .y1    (y1),
        .y2    (y2),
        .y3    (y3)
    );

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------
    // Scoreboard bookkeeping
    // ------------------------------------------------------------------
    int total_count = 0;
    int pass_count  = 0;
    int fail_count  = 0;

    // Cycle-path coverage: cycle_seen[0] is the sign/subtract cycle,
    // cycle_seen[1..7] are the shift-add cycles. sub_seen tracks whether
    // both control paths (sub=1, sub=0) of the shared adder/subtractor
    // were exercised.
    bit cycle_seen[8];
    bit sub_seen[2];

    // Race-free coverage sampling: values are stable well before the next
    // posedge, so sampling on negedge cleanly observes the control signals
    // that were active during that clock cycle (no dependence on process
    // scheduling order relative to the DUT's always_ff, unlike sampling
    // immediately after posedge would be).
    always @(negedge clk) begin
        if (dut.busy) begin
            logic [2:0] cyc_idx;
            cyc_idx = dut.load ? 3'd0 : dut.cnt;
            cycle_seen[cyc_idx] <= 1'b1;
            sub_seen[dut.sub]   <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Driver + scoreboard task: apply one vector, wait for done, compare
    // against the DPI golden model.
    // ------------------------------------------------------------------
    task automatic apply_and_check(
        input logic signed [XW-1:0] tx0,
        input logic signed [XW-1:0] tx1,
        input logic signed [XW-1:0] tx2,
        input logic signed [XW-1:0] tx3,
        input string                label
    );
        int g0, g1, g2, g3;
        int cyc_guard;

        // wait until DUT is idle before issuing a new start
        while (busy) @(negedge clk);

        @(negedge clk);
        x0 = tx0; x1 = tx1; x2 = tx2; x3 = tx3;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // wait for the done pulse (bounded wait as a safety net against a
        // stuck DUT hanging the whole regression)
        cyc_guard = 0;
        while (!done) begin
            @(negedge clk);
            cyc_guard++;
            if (cyc_guard > 64) begin
                $display("FAIL[timeout] %s: done never asserted for x=(%0d,%0d,%0d,%0d)",
                          label, tx0, tx1, tx2, tx3);
                fail_count++;
                total_count++;
                return;
            end
        end

        golden_matvec(tx0, tx1, tx2, tx3, g0, g1, g2, g3);

        total_count++;
        if (y0 !== YW'(g0) || y1 !== YW'(g1) || y2 !== YW'(g2) || y3 !== YW'(g3)) begin
            fail_count++;
            $display("FAIL[%0d] %s x=(%0d,%0d,%0d,%0d) DUT y=(%0d,%0d,%0d,%0d) EXP y=(%0d,%0d,%0d,%0d)",
                      total_count, label, tx0, tx1, tx2, tx3,
                      y0, y1, y2, y3, g0, g1, g2, g3);
        end else begin
            pass_count++;
        end
    endtask

    // Fixed set of extreme values used to force all-same-extreme vectors.
    localparam logic signed [XW-1:0] SAME_EXTREME_VALS[4] = '{-8'sd128, 8'sd127, -8'sd1, 8'sd1};

    // ------------------------------------------------------------------
    // Biased random x generator: skews toward the signed 8-bit extremes
    // (+/-128/127 and near-extreme values) rather than a purely uniform
    // distribution.
    // ------------------------------------------------------------------
    function automatic logic signed [XW-1:0] biased_x();
        logic signed [XW-1:0] extremes[7] = '{-128, -127, 127, 126, -1, 0, 1};
        int pick;
        pick = $urandom_range(0, 99);
        if (pick < 40) begin
            biased_x = extremes[$urandom_range(0, 6)];
        end else begin
            // uniform 0..255 shifted into the signed 8-bit range -128..127
            biased_x = XW'($urandom_range(0, 255) - 128);
        end
    endfunction

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        int r;
        logic signed [XW-1:0] rx0, rx1, rx2, rx3;

        rst_n = 1'b0;
        start = 1'b0;
        x0 = '0; x1 = '0; x2 = '0; x3 = '0;
        for (int i = 0; i < 8; i++) cycle_seen[i] = 1'b0;
        sub_seen[0] = 1'b0;
        sub_seen[1] = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("=== Directed tests ===");
        apply_and_check(8'sd0,    8'sd0,    8'sd0,    8'sd0,    "all-zero");
        apply_and_check(-8'sd128, -8'sd128, -8'sd128, -8'sd128, "all-neg128");
        apply_and_check(8'sd127,  8'sd127,  8'sd127,  8'sd127,  "all-pos127");
        apply_and_check(-8'sd128, 8'sd127,  -8'sd1,   8'sd64,   "mixed-sign");
        // Near-worst-case magnitude for this specific matrix A: row 0's
        // coefficients are (-128, 127, 3, -1); aligning x's signs with each
        // coefficient's sign maximizes |y0| (~33022, well inside the
        // 18-bit signed range but the largest reachable magnitude for A).
        // Note: the 65536 figure used to size the accumulator is the
        // generic 4*128*128 bound, not a value this specific A actually
        // reaches -- see README.
        apply_and_check(-8'sd128, 8'sd127,  8'sd127,  -8'sd128, "near-worst-case-magnitude");

        $display("=== Random regression: %0d vectors ===", NUM_RANDOM);
        for (r = 0; r < NUM_RANDOM; r++) begin
            // Occasionally force all four inputs to the same extreme value
            // to stress the all-same-sign worst-case pattern explicitly.
            if ($urandom_range(0, 99) < 10) begin
                logic signed [XW-1:0] v;
                v = SAME_EXTREME_VALS[$urandom_range(0, 3)];
                rx0 = v; rx1 = v; rx2 = v; rx3 = v;
            end else begin
                rx0 = biased_x();
                rx1 = biased_x();
                rx2 = biased_x();
                rx3 = biased_x();
            end
            apply_and_check(rx0, rx1, rx2, rx3, $sformatf("random-%0d", r));
        end

        // ------------------------------------------------------------
        // Final report
        // ------------------------------------------------------------
        $display("========================================");
        $display(" Scoreboard summary");
        $display("   total : %0d", total_count);
        $display("   pass  : %0d", pass_count);
        $display("   fail  : %0d", fail_count);
        $display("========================================");

        begin
            bit cyc_ok, sub_ok;
            cyc_ok = 1'b1;
            sub_ok = sub_seen[0] && sub_seen[1];
            for (int i = 0; i < 8; i++) begin
                if (!cycle_seen[i]) cyc_ok = 1'b0;
            end
            $display(" Cycle-path coverage");
            $display("   all 8 shift cycles exercised : %s", cyc_ok ? "YES" : "NO");
            $display("   sub=1 (cycle 0) exercised     : %s", sub_seen[1] ? "YES" : "NO");
            $display("   sub=0 (cycles 1-7) exercised  : %s", sub_seen[0] ? "YES" : "NO");
            $display("========================================");
            if (!cyc_ok || !sub_ok) begin
                fail_count++;
                $display("FAIL: cycle/control-path coverage incomplete");
            end
        end

        if (fail_count > 0) begin
            $fatal(1, "REGRESSION FAILED: %0d/%0d checks failed", fail_count, total_count);
        end else begin
            $display("REGRESSION PASSED: %0d/%0d checks passed", pass_count, total_count);
            $finish;
        end
    end

endmodule
