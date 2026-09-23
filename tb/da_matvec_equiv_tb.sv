// da_matvec_equiv_tb.sv
//
// Lockstep equivalence testbench: the original MSB-first da_matvec_mult
// and the LSB-first Offset-Binary-Coding variant da_matvec_mult_obc run
// side by side on identical stimulus, for SEVERAL different coefficient
// matrices at once (A_FLAT is a per-instance parameter, so each matrix is
// just another pair of instances in the same simulation).
//
// Why this exists alongside tb/da_matvec_tb.sv:
//   - The main regression exercises only the DEFAULT matrix. That matrix
//     needs fewer accumulator bits than a worst-case one, so a datapath
//     that is too narrow for other matrices (the OBC adder width is the
//     classic example) would pass it untouched. Here, matrices such as
//     all -128 push the OBC adder to +/-1024, its true worst case.
//   - It needs no DPI golden model and works for ANY matrix: the expected
//     output is recomputed directly from the instance's own A_FLAT.
//
// Per matrix, on every completed computation, all of these must agree:
//   original y == expected y,  OBC y == expected y   (so original == OBC)
// and on EVERY clock cycle:
//   original busy == OBC busy,  original done == OBC done
// (identical handshake timing, cycle for cycle).
//
// Prints REGRESSION PASSED / uses $fatal on failure, same as the main
// testbench, so the same wrapper scripts and CI greps work unchanged.

`timescale 1ns/1ps

// ----------------------------------------------------------------------
// One matrix's pair of DUTs plus its checker.
// ----------------------------------------------------------------------
module da_equiv_checker #(
    parameter string NAME = "default",
    parameter int signed A_FLAT [16] = '{
`include "matrix_a.inc"
    }
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic                start,
    input  logic signed [7:0]   x0,
    input  logic signed [7:0]   x1,
    input  logic signed [7:0]   x2,
    input  logic signed [7:0]   x3,
    output int                  checks,           // completed computations checked
    output int                  lockstep_cycles,  // cycles busy/done compared
    output int                  errors
);

    localparam int XW = 8;
    localparam int YW = 18;

    logic busy_o, done_o, busy_b, done_b;
    logic signed [YW-1:0] yo0, yo1, yo2, yo3;
    logic signed [YW-1:0] yb0, yb1, yb2, yb3;

    da_matvec_mult #(.A_FLAT(A_FLAT)) u_orig (
        .clk(clk), .rst_n(rst_n), .start(start),
        .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .busy(busy_o), .done(done_o),
        .y0(yo0), .y1(yo1), .y2(yo2), .y3(yo3)
    );

    da_matvec_mult_obc #(.A_FLAT(A_FLAT)) u_obc (
        .clk(clk), .rst_n(rst_n), .start(start),
        .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .busy(busy_b), .done(done_b),
        .y0(yb0), .y1(yb1), .y2(yb2), .y3(yb3)
    );

    // Capture x at the first cycle of each computation (first busy cycle
    // after an idle one), so the expected value is computed from what the
    // DUTs actually sampled even if the driver changes x afterwards.
    logic prev_busy;
    logic signed [XW-1:0] xl0, xl1, xl2, xl3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_busy <= 1'b0;
            xl0 <= '0; xl1 <= '0; xl2 <= '0; xl3 <= '0;
        end else begin
            if (busy_o && !prev_busy) begin
                xl0 <= x0; xl1 <= x1; xl2 <= x2; xl3 <= x3;
            end
            prev_busy <= busy_o;
        end
    end

    int prints;

    // Sampled on the falling edge, well away from the DUTs' rising-edge
    // updates, so all combinational values have settled (same technique
    // as the main testbench's coverage/protocol monitors).
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            checks          <= 0;
            lockstep_cycles <= 0;
            errors          <= 0;
            prints          <= 0;
        end else begin
            int inc_err;
            int e0, e1, e2, e3;
            inc_err = 0;

            lockstep_cycles <= lockstep_cycles + 1;

            if (busy_o !== busy_b) begin
                inc_err++;
                if (prints < 10) $display("EQUIV FAIL [%s] busy differs: orig=%0b obc=%0b at %0t",
                                           NAME, busy_o, busy_b, $time);
            end
            if (done_o !== done_b) begin
                inc_err++;
                if (prints < 10) $display("EQUIV FAIL [%s] done differs: orig=%0b obc=%0b at %0t",
                                           NAME, done_o, done_b, $time);
            end

            if (done_o) begin
                e0 = A_FLAT[0]*xl0  + A_FLAT[1]*xl1  + A_FLAT[2]*xl2  + A_FLAT[3]*xl3;
                e1 = A_FLAT[4]*xl0  + A_FLAT[5]*xl1  + A_FLAT[6]*xl2  + A_FLAT[7]*xl3;
                e2 = A_FLAT[8]*xl0  + A_FLAT[9]*xl1  + A_FLAT[10]*xl2 + A_FLAT[11]*xl3;
                e3 = A_FLAT[12]*xl0 + A_FLAT[13]*xl1 + A_FLAT[14]*xl2 + A_FLAT[15]*xl3;

                checks <= checks + 1;

                if (int'(yo0) !== e0 || int'(yo1) !== e1 || int'(yo2) !== e2 || int'(yo3) !== e3) begin
                    inc_err++;
                    if (prints < 10) $display("EQUIV FAIL [%s] ORIGINAL x=(%0d,%0d,%0d,%0d) y=(%0d,%0d,%0d,%0d) expected=(%0d,%0d,%0d,%0d)",
                                               NAME, xl0, xl1, xl2, xl3, yo0, yo1, yo2, yo3, e0, e1, e2, e3);
                end
                if (int'(yb0) !== e0 || int'(yb1) !== e1 || int'(yb2) !== e2 || int'(yb3) !== e3) begin
                    inc_err++;
                    if (prints < 10) $display("EQUIV FAIL [%s] OBC      x=(%0d,%0d,%0d,%0d) y=(%0d,%0d,%0d,%0d) expected=(%0d,%0d,%0d,%0d)",
                                               NAME, xl0, xl1, xl2, xl3, yb0, yb1, yb2, yb3, e0, e1, e2, e3);
                end
            end

            if (inc_err != 0) begin
                errors <= errors + inc_err;
                prints <= prints + 1;
            end
        end
    end

endmodule

// ----------------------------------------------------------------------
// Top level: shared clock/reset/stimulus broadcast to one checker per
// matrix.
// ----------------------------------------------------------------------
module da_matvec_equiv_tb;

    localparam int XW = 8;
    localparam int CLK_PERIOD = 10;
    localparam int NUM_RANDOM = 10000;
    localparam int NUM_CFG = 6;

    // Matrices under test (flat row-major, same convention as
    // common/matrix_a.inc). The first is the project's real matrix (the
    // checker's default, pulled from that file); the rest are chosen to
    // stress the datapath widths and the offset/sign handling.
    localparam int signed CFG_NEG128 [16] = '{
        -128, -128, -128, -128,
        -128, -128, -128, -128,
        -128, -128, -128, -128,
        -128, -128, -128, -128
    };
    localparam int signed CFG_POS127 [16] = '{
         127,  127,  127,  127,
         127,  127,  127,  127,
         127,  127,  127,  127,
         127,  127,  127,  127
    };
    localparam int signed CFG_CHECKER [16] = '{
        -128,  127, -128,  127,
         127, -128,  127, -128,
        -128,  127, -128,  127,
         127, -128,  127, -128
    };
    localparam int signed CFG_MIX [16] = '{
          93,  -77,   12, -128,
          -1,    0,  127,  -45,
          64,   64,  -64,  -64,
        -100,   33,    1,  127
    };
    localparam int signed CFG_SPARSE [16] = '{
           0,    0,    0,    0,
           0,    0,    0,    1,
          -1,    0,    0,    0,
           0, -128,    0,    0
    };

    logic                 clk;
    logic                 rst_n;
    logic                 start;
    logic signed [XW-1:0] x0, x1, x2, x3;

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    int c0, c1, c2, c3, c4, c5;       // completed computations checked
    int l0, l1, l2, l3, l4, l5;       // lockstep cycles compared
    int e0, e1, e2, e3, e4, e5;       // errors

    da_equiv_checker #(.NAME("real matrix (common/matrix_a.inc)")) chk0 (
        .clk(clk), .rst_n(rst_n), .start(start), .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .checks(c0), .lockstep_cycles(l0), .errors(e0));
    da_equiv_checker #(.NAME("all -128"), .A_FLAT(CFG_NEG128)) chk1 (
        .clk(clk), .rst_n(rst_n), .start(start), .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .checks(c1), .lockstep_cycles(l1), .errors(e1));
    da_equiv_checker #(.NAME("all +127"), .A_FLAT(CFG_POS127)) chk2 (
        .clk(clk), .rst_n(rst_n), .start(start), .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .checks(c2), .lockstep_cycles(l2), .errors(e2));
    da_equiv_checker #(.NAME("checkerboard -128/+127"), .A_FLAT(CFG_CHECKER)) chk3 (
        .clk(clk), .rst_n(rst_n), .start(start), .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .checks(c3), .lockstep_cycles(l3), .errors(e3));
    da_equiv_checker #(.NAME("mixed"), .A_FLAT(CFG_MIX)) chk4 (
        .clk(clk), .rst_n(rst_n), .start(start), .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .checks(c4), .lockstep_cycles(l4), .errors(e4));
    da_equiv_checker #(.NAME("sparse / zero row"), .A_FLAT(CFG_SPARSE)) chk5 (
        .clk(clk), .rst_n(rst_n), .start(start), .x0(x0), .x1(x1), .x2(x2), .x3(x3),
        .checks(c5), .lockstep_cycles(l5), .errors(e5));

    // ------------------------------------------------------------------
    // Stimulus: broadcast one vector to every checker. All instances run
    // in lockstep, so a fixed schedule (start pulse, then wait out the 8
    // busy cycles plus the done cycle) is enough and cannot hang.
    // ------------------------------------------------------------------
    int vec_count;

    task automatic apply(
        input logic signed [XW-1:0] tx0,
        input logic signed [XW-1:0] tx1,
        input logic signed [XW-1:0] tx2,
        input logic signed [XW-1:0] tx3
    );
        x0 = tx0; x1 = tx1; x2 = tx2; x3 = tx3;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        repeat (8) @(negedge clk);
        vec_count++;
    endtask

    localparam logic signed [XW-1:0] BIT_WEIGHTS[8] =
        '{8'sd1, 8'sd2, 8'sd4, 8'sd8, 8'sd16, 8'sd32, 8'sd64, -8'sd128};
    localparam logic signed [XW-1:0] CURATED_VALS[8] =
        '{-8'sd128, -8'sd127, -8'sd1, 8'sd0, 8'sd1, 8'sd64, 8'sd65, 8'sd127};
    localparam int PAIR_A[6] = '{0, 0, 0, 1, 1, 2};
    localparam int PAIR_B[6] = '{1, 2, 3, 2, 3, 3};

    function automatic logic signed [XW-1:0] biased_x();
        localparam logic signed [XW-1:0] EXTREMES[11] =
            '{-128, -127, -126, 127, 126, 125, -1, 0, 1, 2, -2};
        int pick;
        int offset;
        pick = $urandom_range(0, 99);
        if (pick < 30) begin
            biased_x = EXTREMES[$urandom_range(0, 10)];
        end else if (pick < 50) begin
            offset = $urandom_range(0, 6);
            if ($urandom_range(0, 1) == 1)
                biased_x = XW'(-128 + offset);
            else
                biased_x = XW'(127 - offset);
        end else begin
            biased_x = XW'($urandom_range(0, 255) - 128);
        end
    endfunction

    initial begin
        int ch, b, m, val, p, ca, cb, va, vb, i0, i1, i2, i3, r;
        int seed;
        int seed_reseed_unused;
        int total_checks, total_errors, total_lockstep, bad_counts;
        logic signed [XW-1:0] w0, w1, w2, w3;

        if (!$value$plusargs("SEED=%d", seed)) seed = 32'hDA5EED;
        $display("Random seed = %0d (override with +SEED=<n> for a fresh sequence)", seed);
        seed_reseed_unused = $urandom(seed);

        vec_count = 0;
        rst_n = 1'b0;
        start = 1'b0;
        x0 = '0; x1 = '0; x2 = '0; x3 = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("=== Hand-picked edge cases ===");
        apply(8'sd0,    8'sd0,    8'sd0,    8'sd0);
        apply(-8'sd128, -8'sd128, -8'sd128, -8'sd128);
        apply(8'sd127,  8'sd127,  8'sd127,  8'sd127);
        apply(-8'sd128, 8'sd127,  -8'sd1,   8'sd64);
        apply(-8'sd128, 8'sd127,  8'sd127,  -8'sd128);
        apply(8'sd127,  8'sd127,  8'sd127,  8'sd127);   // back-to-back repeat
        apply(-8'sd128, -8'sd128, -8'sd128, -8'sd128);  // sign flip right after

        $display("=== Per-channel bit-position walk (32) ===");
        for (ch = 0; ch < 4; ch++) begin
            for (b = 0; b < 8; b++) begin
                w0 = '0; w1 = '0; w2 = '0; w3 = '0;
                case (ch)
                    0: w0 = BIT_WEIGHTS[b];
                    1: w1 = BIT_WEIGHTS[b];
                    2: w2 = BIT_WEIGHTS[b];
                    3: w3 = BIT_WEIGHTS[b];
                endcase
                apply(w0, w1, w2, w3);
            end
        end

        $display("=== Hypercube corners, all combinations of -128/127 (16) ===");
        for (m = 0; m < 16; m++) begin
            apply(m[0] ? -8'sd128 : 8'sd127, m[1] ? -8'sd128 : 8'sd127,
                  m[2] ? -8'sd128 : 8'sd127, m[3] ? -8'sd128 : 8'sd127);
        end

        $display("=== Exhaustive single-channel sweep: 4 x 256 ===");
        for (ch = 0; ch < 4; ch++) begin
            for (val = -128; val <= 127; val++) begin
                w0 = '0; w1 = '0; w2 = '0; w3 = '0;
                case (ch)
                    0: w0 = XW'(val);
                    1: w1 = XW'(val);
                    2: w2 = XW'(val);
                    3: w3 = XW'(val);
                endcase
                apply(w0, w1, w2, w3);
            end
        end

        $display("=== Exhaustive curated 4-way Cartesian product: 8^4 ===");
        for (i0 = 0; i0 < 8; i0++)
            for (i1 = 0; i1 < 8; i1++)
                for (i2 = 0; i2 < 8; i2++)
                    for (i3 = 0; i3 < 8; i3++)
                        apply(CURATED_VALS[i0], CURATED_VALS[i1], CURATED_VALS[i2], CURATED_VALS[i3]);

        $display("=== Exhaustive pairwise sweep: 6 pairs x 256 x 256 ===");
        for (p = 0; p < 6; p++) begin
            ca = PAIR_A[p];
            cb = PAIR_B[p];
            for (va = -128; va <= 127; va++) begin
                for (vb = -128; vb <= 127; vb++) begin
                    w0 = '0; w1 = '0; w2 = '0; w3 = '0;
                    case (ca)
                        0: w0 = XW'(va);
                        1: w1 = XW'(va);
                        2: w2 = XW'(va);
                        3: w3 = XW'(va);
                    endcase
                    case (cb)
                        0: w0 = XW'(vb);
                        1: w1 = XW'(vb);
                        2: w2 = XW'(vb);
                        3: w3 = XW'(vb);
                    endcase
                    apply(w0, w1, w2, w3);
                end
            end
        end

        $display("=== Constrained-random regression: %0d vectors ===", NUM_RANDOM);
        for (r = 0; r < NUM_RANDOM; r++) begin
            apply(biased_x(), biased_x(), biased_x(), biased_x());
        end

        repeat (2) @(negedge clk);

        // --------------------------------------------------------------
        // Final report
        // --------------------------------------------------------------
        total_checks   = c0 + c1 + c2 + c3 + c4 + c5;
        total_errors   = e0 + e1 + e2 + e3 + e4 + e5;
        total_lockstep = l0 + l1 + l2 + l3 + l4 + l5;

        // Every matrix's checker must have seen every vector complete;
        // otherwise a checker silently checking nothing would look like a pass.
        bad_counts = 0;
        if (c0 != vec_count) bad_counts++;
        if (c1 != vec_count) bad_counts++;
        if (c2 != vec_count) bad_counts++;
        if (c3 != vec_count) bad_counts++;
        if (c4 != vec_count) bad_counts++;
        if (c5 != vec_count) bad_counts++;

        $display("========================================");
        $display(" Equivalence summary (%0d vectors x %0d matrices)", vec_count, NUM_CFG);
        $display("   checks per matrix : %0d %0d %0d %0d %0d %0d", c0, c1, c2, c3, c4, c5);
        $display("   errors per matrix : %0d %0d %0d %0d %0d %0d", e0, e1, e2, e3, e4, e5);
        $display("   lockstep cycles compared (busy/done) : %0d", total_lockstep);
        $display("========================================");

        if (total_errors > 0 || bad_counts > 0) begin
            $fatal(1, "EQUIVALENCE FAILED: %0d errors, %0d matrices with wrong check count",
                   total_errors, bad_counts);
        end else begin
            $display("REGRESSION PASSED: %0d/%0d checks passed", total_checks, total_checks);
            $finish;
        end
    end

endmodule
