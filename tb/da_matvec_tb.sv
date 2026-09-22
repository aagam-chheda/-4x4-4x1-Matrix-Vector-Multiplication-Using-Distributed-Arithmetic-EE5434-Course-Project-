// da_matvec_tb.sv
//
// Self-checking testbench + scoreboard for da_matvec_mult. The goal of
// this suite is to actively try to break the DUT, not just demonstrate
// it working: every category below was chosen to target a specific class
// of bug (bit-position/shift-order errors, ROM-address/sign-extension
// errors, accumulator-reset errors, handshake/control-path races,
// overflow-adjacent magnitudes), on top of broad random coverage.
//
//   - DPI-C golden model (dpi/golden_model.c) provides expected results
//     for every single check below -- there are no hardcoded expected
//     outputs anywhere in this file.
//   - Hand-picked directed edge cases: all-zero, all-(-128), all-(+127),
//     a mixed-sign vector, and a near-worst-case-magnitude vector.
//   - Back-to-back regression tests for the accumulator-reset bug found
//     during bring-up (see README): repeated/complementary vectors with
//     no idle gap between them.
//   - Per-channel bit-position walk (32 vectors): each of the 8 bit
//     weights (1,2,4,...,64,-128) applied to each input channel in
//     isolation, to catch any bit-order/shift-register/Horner-weighting
//     bug that a "random" vector might only trigger by chance.
//   - Hypercube corners (16 vectors): every combination of the two most
//     extreme values (-128/127) across all four inputs.
//   - Alternating-bit-pattern vectors (0x55/0xAA and its rotation).
//   - All 24 permutations of the four distinct near-extreme values
//     (127, -128, 126, -127) across the four input slots.
//   - Control/handshake robustness tests: start held high through an
//     entire computation, a spurious start pulse injected mid-computation
//     with different data, and an async reset injected mid-computation --
//     each checks the DUT recovers/behaves correctly, not just that a
//     clean textbook sequence works.
//   - Exhaustive single-channel sweep (1024 vectors): all 256 signed
//     8-bit values on one input channel at a time, others held at 0.
//   - Constrained-random regression: 10000 vectors, generated with a
//     3-tier bias (exact/near-extreme literals, boundary-adjacent
//     jitter, and full uniform) so the corners get disproportionate
//     attention without giving up broad random coverage. Deterministic
//     by default (fixed seed) for reproducible CI runs; override with
//     +SEED=<n> to explore a fresh random sequence.
//   - Coverage tracking (no dependence on simulator-specific functional
//     coverage tooling, so it behaves identically under Verilator and
//     Vivado xsim): all 8 shift cycles, both adder/subtractor control
//     paths (sub=1 on cycle 0, sub=0 on cycles 1-7), and all 16 possible
//     DA ROM addresses are confirmed exercised by the end of the run.
//   - Exits with a nonzero status on any scoreboard mismatch or coverage
//     shortfall (via $fatal), suitable for CI/regression use.

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
    localparam int NUM_RANDOM = 10000;

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
    int total_count;
    int pass_count;
    int fail_count;

    // Cycle-path coverage: cycle_seen[0] is the sign/subtract cycle,
    // cycle_seen[1..7] are the shift-add cycles. sub_seen tracks whether
    // both control paths (sub=1, sub=0) of the shared adder/subtractor
    // were exercised. addr_seen tracks all 16 possible 4-bit DA ROM
    // addresses (one bit per input) actually presented to the ROMs.
    bit cycle_seen[8];
    bit sub_seen[2];
    bit addr_seen[16];

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
            addr_seen[dut.addr] <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Protocol/handshake invariant monitor: independent of whether any
    // particular *result* is numerically correct, these check that the
    // DUT's internal timing contract (as documented in rtl/da_matvec_mult.sv
    // and the README's "Handshake" section) actually holds on every single
    // cycle of every test in the whole regression, not just the specific
    // cycles the directed control-robustness tests happen to probe.
    // Deliberately plain procedural checks (not `assert property` with
    // temporal operators) -- SVA support has historically been the kind of
    // thing that varies between simulators, and this project has already
    // hit two real portability surprises this way with other SV features;
    // plain always-block checks are the same technique already proven
    // portable (Verilator + real Vivado 2024.2) by the coverage monitor
    // above.
    //
    //   1. busy and done are never simultaneously high.
    //   2. done is exactly a 1-cycle pulse (never 2+ cycles in a row).
    //   3. busy is asserted for exactly 8 consecutive cycles per
    //      computation -- not 7, not 9.
    //   4. y0..y3 hold their value from the done cycle until the next
    //      load cycle (i.e. the "holds until next start" contract in the
    //      interface documentation actually holds, not just "probably
    //      does because nothing changes it").
    int  busy_run_length;
    logic prev_busy, prev_done;
    logic monitoring_hold;
    logic signed [YW-1:0] held_y0, held_y1, held_y2, held_y3;

    initial begin
        busy_run_length = 0;
        prev_busy       = 1'b0;
        prev_done       = 1'b0;
        monitoring_hold = 1'b0;
    end

    // Async-sensitive to rst_n (matching the DUT's own reset style) to
    // avoid a sync/async mismatch on the same net between this block and
    // the DUT's always_ff.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_run_length <= 0;
            prev_busy       <= 1'b0;
            prev_done       <= 1'b0;
            monitoring_hold <= 1'b0;
        end else begin
            if (busy && done) begin
                fail_count  <= fail_count + 1;
                total_count <= total_count + 1;
                $display("FAIL[protocol] busy and done both high simultaneously at time %0t", $time);
            end

            if (prev_done && done) begin
                fail_count  <= fail_count + 1;
                total_count <= total_count + 1;
                $display("FAIL[protocol] done stayed high for more than 1 cycle at time %0t", $time);
            end

            if (busy) begin
                busy_run_length <= busy_run_length + 1;
            end else if (prev_busy) begin
                if (busy_run_length != 8) begin
                    fail_count  <= fail_count + 1;
                    total_count <= total_count + 1;
                    $display("FAIL[protocol] busy was high for %0d cycles (expected exactly 8) ending at time %0t",
                              busy_run_length, $time);
                end
                busy_run_length <= 0;
            end

            if (done) begin
                held_y0 <= y0; held_y1 <= y1; held_y2 <= y2; held_y3 <= y3;
                monitoring_hold <= 1'b1;
            end else if (dut.load) begin
                monitoring_hold <= 1'b0;
            end else if (monitoring_hold) begin
                if (y0 !== held_y0 || y1 !== held_y1 || y2 !== held_y2 || y3 !== held_y3) begin
                    fail_count  <= fail_count + 1;
                    total_count <= total_count + 1;
                    $display("FAIL[protocol] y0..y3 changed while idle (must hold until next start) at time %0t", $time);
                end
            end

            prev_busy <= busy;
            prev_done <= done;
        end
    end

    // ------------------------------------------------------------------
    // Driver + scoreboard task: apply one vector, wait for done, compare
    // against the DPI golden model. Waits for the DUT to be idle before
    // issuing start, but with only a single negedge of margin -- back-
    // to-back calls already exercise near-zero-gap restart timing.
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

    // ------------------------------------------------------------------
    // Control/handshake robustness tasks. These don't go through
    // apply_and_check because they deliberately drive start/rst_n in
    // non-textbook ways to probe the FSM's edge behavior.
    // ------------------------------------------------------------------

    // Holds `start` high for the *entire* computation (not just a single
    // pulse), dropping it only once `done` is observed. Confirms the FSM
    // ignores start while active (load = start && !active) rather than
    // restarting mid-computation, and that dropping start exactly at
    // done cleanly prevents any auto-retrigger.
    task automatic test_held_start();
        int g0, g1, g2, g3;
        logic signed [XW-1:0] tx0, tx1, tx2, tx3;
        tx0 = 8'sd50; tx1 = -8'sd77; tx2 = 8'sd13; tx3 = -8'sd1;

        while (busy) @(negedge clk);
        @(negedge clk);
        x0 = tx0; x1 = tx1; x2 = tx2; x3 = tx3;
        start = 1'b1;                 // held high, unlike the usual 1-cycle pulse
        while (!done) @(negedge clk);
        start = 1'b0;                 // dropped in the same negedge done is seen,
                                       // before the next posedge can re-evaluate load

        golden_matvec(tx0, tx1, tx2, tx3, g0, g1, g2, g3);
        total_count++;
        if (y0 !== YW'(g0) || y1 !== YW'(g1) || y2 !== YW'(g2) || y3 !== YW'(g3)) begin
            fail_count++;
            $display("FAIL[%0d] held-start x=(%0d,%0d,%0d,%0d) DUT y=(%0d,%0d,%0d,%0d) EXP y=(%0d,%0d,%0d,%0d)",
                      total_count, tx0, tx1, tx2, tx3, y0, y1, y2, y3, g0, g1, g2, g3);
        end else begin
            pass_count++;
        end

        @(negedge clk);
        if (busy) begin
            total_count++;
            fail_count++;
            $display("FAIL[%0d] held-start: spurious retrigger (busy still high one cycle after done+start-drop)",
                      total_count);
        end
    endtask

    // Kicks off a real computation, then injects a one-cycle spurious
    // `start` pulse with *different* data partway through, mimicking an
    // environment bug that asserts start while busy. Confirms the
    // in-flight computation is unaffected and still produces the result
    // for the original vector, not the glitch vector.
    task automatic test_start_while_busy();
        int g0, g1, g2, g3;
        logic signed [XW-1:0] va0, va1, va2, va3;
        logic signed [XW-1:0] vb0, vb1, vb2, vb3;
        va0 = 8'sd100; va1 = -8'sd45; va2 = 8'sd7;    va3 = -8'sd120;
        vb0 = -8'sd128; vb1 = 8'sd127; vb2 = -8'sd1;  vb3 = 8'sd64;

        while (busy) @(negedge clk);
        @(negedge clk);
        x0 = va0; x1 = va1; x2 = va2; x3 = va3;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        repeat (2) @(negedge clk);
        if (!busy) begin
            total_count++;
            fail_count++;
            $display("FAIL[%0d] start-while-busy: expected busy high mid-computation before glitch injection",
                      total_count);
            return;
        end

        // glitch: different data, one-cycle start pulse, mid-computation
        x0 = vb0; x1 = vb1; x2 = vb2; x3 = vb3;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        x0 = va0; x1 = va1; x2 = va2; x3 = va3;   // restore, for clarity of intent

        while (!done) @(negedge clk);

        golden_matvec(va0, va1, va2, va3, g0, g1, g2, g3);
        total_count++;
        if (y0 !== YW'(g0) || y1 !== YW'(g1) || y2 !== YW'(g2) || y3 !== YW'(g3)) begin
            fail_count++;
            $display("FAIL[%0d] start-while-busy: glitch corrupted in-flight computation. DUT y=(%0d,%0d,%0d,%0d) EXP y=(%0d,%0d,%0d,%0d)",
                      total_count, y0, y1, y2, y3, g0, g1, g2, g3);
        end else begin
            pass_count++;
        end
    endtask

    // Injects an async reset partway through a computation. Confirms
    // busy/done cleanly deassert and that a subsequent computation
    // still produces a correct result (clean recovery, not just "didn't
    // crash the simulator").
    task automatic test_reset_midway();
        logic signed [XW-1:0] tx0, tx1, tx2, tx3;
        tx0 = 8'sd77; tx1 = -8'sd33; tx2 = 8'sd5; tx3 = -8'sd90;

        while (busy) @(negedge clk);
        @(negedge clk);
        x0 = tx0; x1 = tx1; x2 = tx2; x3 = tx3;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        repeat (3) @(negedge clk);
        if (!busy) begin
            total_count++;
            fail_count++;
            $display("FAIL[%0d] reset-midway: expected busy high before mid-computation reset", total_count);
            return;
        end

        rst_n = 1'b0;
        repeat (2) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        total_count++;
        if (busy || done) begin
            fail_count++;
            $display("FAIL[%0d] reset-midway: busy/done not cleanly deasserted after mid-computation reset (busy=%0b done=%0b)",
                      total_count, busy, done);
        end else begin
            pass_count++;
        end

        // Confirm clean recovery with a fresh, correctly-checked computation.
        apply_and_check(8'sd42, -8'sd17, 8'sd99, -8'sd3, "post-reset-recovery");
    endtask

    // Fixed set of extreme values used to force all-same-extreme vectors.
    localparam logic signed [XW-1:0] SAME_EXTREME_VALS[4] = '{-8'sd128, 8'sd127, -8'sd1, 8'sd1};

    // Per-channel bit-position walk: one weight per DA shift-cycle bit
    // position, MSB (sign, -128) last to match the visual bit order.
    localparam logic signed [XW-1:0] BIT_WEIGHTS[8] =
        '{8'sd1, 8'sd2, 8'sd4, 8'sd8, 8'sd16, 8'sd32, 8'sd64, -8'sd128};

    // All 24 permutations of the four distinct near-extreme values
    // (127, -128, 126, -127) across the four input slots.
    localparam logic signed [XW-1:0] BOUNDARY_PERMS[24][4] = '{
        '{127, -128, 126, -127},
        '{127, -128, -127, 126},
        '{127, 126, -128, -127},
        '{127, 126, -127, -128},
        '{127, -127, -128, 126},
        '{127, -127, 126, -128},
        '{-128, 127, 126, -127},
        '{-128, 127, -127, 126},
        '{-128, 126, 127, -127},
        '{-128, 126, -127, 127},
        '{-128, -127, 127, 126},
        '{-128, -127, 126, 127},
        '{126, 127, -128, -127},
        '{126, 127, -127, -128},
        '{126, -128, 127, -127},
        '{126, -128, -127, 127},
        '{126, -127, 127, -128},
        '{126, -127, -128, 127},
        '{-127, 127, -128, 126},
        '{-127, 127, 126, -128},
        '{-127, -128, 127, 126},
        '{-127, -128, 126, 127},
        '{-127, 126, 127, -128},
        '{-127, 126, -128, 127}
    };

    // All 6 unordered pairs of the 4 input channels, for the exhaustive
    // pairwise sweep below.
    localparam int PAIR_A[6] = '{0, 0, 0, 1, 1, 2};
    localparam int PAIR_B[6] = '{1, 2, 3, 2, 3, 3};

    // 8 "interesting" values (both extremes, near-extremes on each side,
    // zero, +/-1, and a non-corner adjacent pair 64/65) for the exhaustive
    // curated 4-way Cartesian product below.
    localparam logic signed [XW-1:0] CURATED_VALS[8] =
        '{-8'sd128, -8'sd127, -8'sd1, 8'sd0, 8'sd1, 8'sd64, 8'sd65, 8'sd127};

    // ------------------------------------------------------------------
    // Biased random x generator, 3-tier:
    //   30% - exact/near-extreme literal set
    //   20% - boundary jitter: a small random offset inward from one of
    //         the two rails, stressing values adjacent to (not just at)
    //         the extremes
    //   50% - full uniform 8-bit signed range, for broad coverage
    // ------------------------------------------------------------------
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
            // uniform 0..255 shifted into the signed 8-bit range -128..127
            biased_x = XW'($urandom_range(0, 255) - 128);
        end
    endfunction

    // ------------------------------------------------------------------
    // Test sequence
    // ------------------------------------------------------------------
    initial begin
        int r, ch, b, m, val;
        int seed;
        int seed_reseed_unused;
        logic signed [XW-1:0] rx0, rx1, rx2, rx3;
        logic signed [XW-1:0] wv0, wv1, wv2, wv3;
        logic signed [XW-1:0] cv0, cv1, cv2, cv3;
        logic signed [XW-1:0] sv0, sv1, sv2, sv3;
        int p, ca, cb, va, vb;
        logic signed [XW-1:0] pv0, pv1, pv2, pv3;
        int i0, i1, i2, i3;

        if (!$value$plusargs("SEED=%d", seed)) seed = 32'hDA5EED;
        $display("Random seed = %0d (override with +SEED=<n> for a fresh sequence)", seed);
        // Reseed via a genuine assignment (RHS is unambiguously a
        // function call), not `void'($urandom(seed));` or `$srandom(seed);`
        // as a bare statement -- confirmed against real runs that neither
        // of those two forms is portable: Vivado 2024.2's xsim rejects
        // $urandom(seed) called as a bare statement ("urandom system task
        // is not supported"), and this Verilator build doesn't implement
        // $srandom at all ("Unsupported or unknown PLI call"). Assigning
        // the (unused) return value works on both.
        seed_reseed_unused = $urandom(seed);

        rst_n = 1'b0;
        start = 1'b0;
        x0 = '0; x1 = '0; x2 = '0; x3 = '0;
        total_count = 0;
        pass_count  = 0;
        fail_count  = 0;
        for (int i = 0; i < 8; i++) cycle_seen[i] = 1'b0;
        for (int i = 0; i < 2; i++) sub_seen[i] = 1'b0;
        for (int i = 0; i < 16; i++) addr_seen[i] = 1'b0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("=== Directed: hand-picked edge cases ===");
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

        $display("=== Directed: back-to-back accumulator-reset regression ===");
        // This exact sequence (repeated/complementary vectors with no
        // idle gap) is what caught the historical bug where the
        // accumulator carried the previous result into the next
        // computation's sign-bit cycle instead of starting from 0.
        apply_and_check(8'sd127, 8'sd127, 8'sd127, 8'sd127,     "back2back-same-1");
        apply_and_check(8'sd127, 8'sd127, 8'sd127, 8'sd127,     "back2back-same-2");
        apply_and_check(8'sd127, 8'sd127, 8'sd127, 8'sd127,     "back2back-same-3");
        apply_and_check(-8'sd128, -8'sd128, -8'sd128, -8'sd128, "back2back-negated-after-positive");
        apply_and_check(8'sd0,   8'sd0,   8'sd0,   8'sd0,       "back2back-zero-after-extreme");
        apply_and_check(8'sd127, 8'sd127, 8'sd127, 8'sd127,     "back2back-extreme-after-zero");

        $display("=== Directed: per-channel bit-position walk (32 vectors) ===");
        for (ch = 0; ch < 4; ch++) begin
            for (b = 0; b < 8; b++) begin
                wv0 = '0; wv1 = '0; wv2 = '0; wv3 = '0;
                case (ch)
                    0: wv0 = BIT_WEIGHTS[b];
                    1: wv1 = BIT_WEIGHTS[b];
                    2: wv2 = BIT_WEIGHTS[b];
                    3: wv3 = BIT_WEIGHTS[b];
                endcase
                apply_and_check(wv0, wv1, wv2, wv3, $sformatf("bitwalk-ch%0d-bit%0d", ch, b));
            end
        end

        $display("=== Directed: hypercube corners, all combinations of -128/127 (16 vectors) ===");
        for (m = 0; m < 16; m++) begin
            cv0 = m[0] ? -8'sd128 : 8'sd127;
            cv1 = m[1] ? -8'sd128 : 8'sd127;
            cv2 = m[2] ? -8'sd128 : 8'sd127;
            cv3 = m[3] ? -8'sd128 : 8'sd127;
            apply_and_check(cv0, cv1, cv2, cv3, $sformatf("hypercube-corner-%0d", m));
        end

        $display("=== Directed: alternating bit-pattern vectors ===");
        apply_and_check(8'sd85,  -8'sd86, 8'sd85,  -8'sd86, "alternating-0x55-0xAA");
        apply_and_check(-8'sd86, 8'sd85,  -8'sd86, 8'sd85,  "alternating-0xAA-0x55");

        $display("=== Directed: boundary-value permutations (24 vectors) ===");
        for (m = 0; m < 24; m++) begin
            apply_and_check(BOUNDARY_PERMS[m][0], BOUNDARY_PERMS[m][1],
                             BOUNDARY_PERMS[m][2], BOUNDARY_PERMS[m][3],
                             $sformatf("boundary-perm-%0d", m));
        end

        $display("=== Directed: control/handshake robustness ===");
        test_held_start();
        test_start_while_busy();
        test_reset_midway();

        $display("=== Exhaustive single-channel sweep: 4 x 256 = 1024 vectors ===");
        for (ch = 0; ch < 4; ch++) begin
            for (val = -128; val <= 127; val++) begin
                sv0 = '0; sv1 = '0; sv2 = '0; sv3 = '0;
                case (ch)
                    0: sv0 = XW'(val);
                    1: sv1 = XW'(val);
                    2: sv2 = XW'(val);
                    3: sv3 = XW'(val);
                endcase
                apply_and_check(sv0, sv1, sv2, sv3, $sformatf("sweep-ch%0d-val%0d", ch, val));
            end
        end

        // The single-channel sweep above is exhaustive per channel but
        // never tests *combinations* -- exactly the class of bug the
        // mutation-testing writeup in the README describes catching only
        // by luck (a channel-address-swap mutant that the all-same-value
        // directed tests completely missed). This sweep closes that gap
        // for real: every pair of channels, every one of the full
        // 256x256 combinations, guaranteed rather than probabilistic.
        $display("=== Exhaustive pairwise sweep: 6 pairs x 256 x 256 = 393216 vectors ===");
        for (p = 0; p < 6; p++) begin
            ca = PAIR_A[p];
            cb = PAIR_B[p];
            for (va = -128; va <= 127; va++) begin
                for (vb = -128; vb <= 127; vb++) begin
                    pv0 = '0; pv1 = '0; pv2 = '0; pv3 = '0;
                    case (ca)
                        0: pv0 = XW'(va);
                        1: pv1 = XW'(va);
                        2: pv2 = XW'(va);
                        3: pv3 = XW'(va);
                    endcase
                    case (cb)
                        0: pv0 = XW'(vb);
                        1: pv1 = XW'(vb);
                        2: pv2 = XW'(vb);
                        3: pv3 = XW'(vb);
                    endcase
                    apply_and_check(pv0, pv1, pv2, pv3,
                                     $sformatf("pairwise-ch%0d-ch%0d-va%0d-vb%0d", ca, cb, va, vb));
                end
            end
        end

        // Full 4-way combinations (not just pairs, not just corners) for
        // a curated set of the values most likely to expose a bug: both
        // extremes, near-extremes on each side, zero, +/-1, and a
        // non-corner adjacent pair (64/65) to catch carry-propagation
        // bugs that only show up away from the extremes.
        $display("=== Exhaustive curated 4-way Cartesian product: 8^4 = 4096 vectors ===");
        for (i0 = 0; i0 < 8; i0++) begin
            for (i1 = 0; i1 < 8; i1++) begin
                for (i2 = 0; i2 < 8; i2++) begin
                    for (i3 = 0; i3 < 8; i3++) begin
                        apply_and_check(CURATED_VALS[i0], CURATED_VALS[i1], CURATED_VALS[i2], CURATED_VALS[i3],
                                         $sformatf("curated4-%0d-%0d-%0d-%0d", i0, i1, i2, i3));
                    end
                end
            end
        end

        $display("=== Constrained-random regression: %0d vectors ===", NUM_RANDOM);
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
            bit cyc_ok, sub_ok, addr_ok;
            int addr_hit_count;
            cyc_ok = 1'b1;
            sub_ok = sub_seen[0] && sub_seen[1];
            addr_ok = 1'b1;
            addr_hit_count = 0;
            for (int i = 0; i < 8; i++) begin
                if (!cycle_seen[i]) cyc_ok = 1'b0;
            end
            for (int i = 0; i < 16; i++) begin
                if (addr_seen[i]) addr_hit_count++;
                else addr_ok = 1'b0;
            end
            $display(" Cycle/address coverage");
            $display("   all 8 shift cycles exercised   : %s", cyc_ok ? "YES" : "NO");
            $display("   sub=1 (cycle 0) exercised       : %s", sub_seen[1] ? "YES" : "NO");
            $display("   sub=0 (cycles 1-7) exercised    : %s", sub_seen[0] ? "YES" : "NO");
            $display("   DA ROM addresses exercised      : %0d/16", addr_hit_count);
            $display("========================================");
            if (!cyc_ok || !sub_ok || !addr_ok) begin
                fail_count++;
                $display("FAIL: cycle/control-path/address coverage incomplete");
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
