// da_matvec_mult_obc.sv
//
// Drop-in variant of da_matvec_mult (same ports, same parameters, same
// 8-cycle busy/done handshake, same y-holds-until-next-start contract)
// built with Offset Binary Coding (OBC) and LSB-first, right-shifting
// accumulation instead of the original's MSB-first, left-shifting Horner
// scheme. Same y = A*x results, different hardware:
//
//                          da_matvec_mult      da_matvec_mult_obc
//   bit order              MSB first           LSB first
//   ROM per row            16 entries          8 entries (half, via OBC)
//   accumulate             acc <= 2*acc + ROM  U <= (U +/- ROM) >> 1
//   adder width per row    YW (18)             WU (12), upper part only
//   extra logic            none                XORs on address, offset mux
//
// Derivation. For two's-complement x with bits b7..b0, define c_k = 2*b_k-1
// (always +1 or -1). Then
//     x = -c_7*2^6 + sum_{k=0..6} c_k * 2^(k-1) - 1/2
// so, with S_k = sum_i A[i]*c_{i,k} and T = sum_i A[i],
//     2*y = sum_{k=0..6} 2^k * S_k  -  2^7 * S_7  -  T.
// S_k is +/-A0 +/-A1 +/-A2 +/-A3. Negating every sign negates S_k, so only
// half of the 16 sign patterns need storing: write S_k = c_0 * M with
//     M = A0 + sum_{i=1..3} A[i] * e_i,   e_i = c_i*c_0 = +1 if b_i==b_0.
// The 3-bit ROM address is therefore {b3 XNOR b0, b2 XNOR b0, b1 XNOR b0}
// (8 entries of M), and b0 chooses whether M is added or subtracted.
// That add/subtract choice is also flipped on the sign-bit cycle, which
// now comes LAST (bit 7), so  sub = ~(b0 ^ is_sign_cycle).
//
// Accumulation. The register is {U, L}: U is the upper accumulator that
// the adder works on, L collects bits shifted out on the right. Each
// cycle:  sum = U +/- M;  U <= sum >>> 1;  L <= {sum[0], L[6:1]}.
// Seeding U with -T before the first cycle (the offset term above) makes
// the final register equal 2*y, so  y = {U, L} taken as an 18-bit value
// (the bit shifted out on the very first cycle is always 0 and is simply
// dropped, hence L is 7 bits). Because the running value only spans the
// magnitude of a few ROM words, the adder needs WU bits, not YW.
//
// Widths (sized for ANY matrix of signed 8-bit coefficients, not just the
// default one, confirmed by a bit-accurate model over extreme and random
// matrices; the default matrix alone would fit in 11 bits, but a matrix of
// all -128 drives the adder to +/-1024):
//   SW = RW+1  ROM word: +/-sums of four 8-bit values reach +/-512
//   WU = RW+2  adder / upper accumulator: |U +/- M| reaches 1024
//   LW = XW-1  shifted-out bits kept
// As in the original, the 3-bit cycle counter fixes XW at 8, and YW must
// satisfy YW-LW <= WU (18-7 = 11 <= 12).
//
// Handshake and internal signal names (load, active, cnt, sub, addr,
// busy) deliberately match the original so the same testbench, coverage
// and protocol monitors apply unchanged. Two things differ observably
// inside: addr is 3 bits (8 ROM entries, not 16), and sub is data
// dependent (b0 xor sign cycle) rather than "cycle 0 only".

`timescale 1ns/1ps

module da_matvec_mult_obc #(
    parameter int N  = 4,   // vector/matrix dimension
    parameter int XW = 8,   // input element width (signed)
    parameter int YW = 18,  // output element width (signed)
    parameter int RW = 10,  // same meaning as the original: width that holds
                             // the original's subset sums (OBC widens it
                             // internally, see SW below)

    // Coefficient matrix, flat row-major (row r, column c at A_FLAT[r*N+c]),
    // a true per-instance parameter exactly as in da_matvec_mult. Default
    // comes from common/matrix_a.inc (resolved via the tool include path).
    parameter int signed A_FLAT [N*N] = '{
`include "matrix_a.inc"
    }
) (
    input  logic                  clk,
    input  logic                  rst_n,    // async active-low reset

    input  logic                  start,    // pulse (1 cycle) to load x and begin
    input  logic signed [XW-1:0]  x0,
    input  logic signed [XW-1:0]  x1,
    input  logic signed [XW-1:0]  x2,
    input  logic signed [XW-1:0]  x3,

    output logic                  busy,     // high for the 8 cycles of computation
    output logic                  done,     // 1-cycle pulse when y0..y3 are valid
    output logic signed [YW-1:0]  y0,
    output logic signed [YW-1:0]  y1,
    output logic signed [YW-1:0]  y2,
    output logic signed [YW-1:0]  y3
);

    localparam int SW = RW + 1;   // ROM word width
    localparam int WU = RW + 2;   // upper accumulator / adder width
    localparam int LW = XW - 1;   // shifted-out register width

    // ------------------------------------------------------------------
    // Elaboration-time tables: per-row OBC ROM (8 entries of M) and
    // per-row offset (-T, seeded into the accumulator on the first cycle).
    // ROM[row][a] = A[row][0] + sum_{i=1..N-1} (a[i-1] ? +A[row][i] : -A[row][i])
    // ------------------------------------------------------------------
    typedef logic signed [SW-1:0] rom_t [2**(N-1)];

    function automatic rom_t build_rom(input logic [$clog2(N)-1:0] row);
        rom_t r;
        int m;
        for (int a = 0; a < 2**(N-1); a++) begin
            m = A_FLAT[row*N];
            for (int i = 1; i < N; i++) begin
                if (a[i-1]) m += A_FLAT[row*N+i];
                else        m -= A_FLAT[row*N+i];
            end
            r[a] = SW'(m);
        end
        return r;
    endfunction

    function automatic int row_sum(input logic [$clog2(N)-1:0] row);
        int s;
        s = 0;
        for (int i = 0; i < N; i++) s += A_FLAT[row*N+i];
        return s;
    endfunction

    localparam rom_t ROM0 = build_rom(2'd0);
    localparam rom_t ROM1 = build_rom(2'd1);
    localparam rom_t ROM2 = build_rom(2'd2);
    localparam rom_t ROM3 = build_rom(2'd3);

    localparam logic signed [WU-1:0] OFF0 = WU'(-row_sum(2'd0));
    localparam logic signed [WU-1:0] OFF1 = WU'(-row_sum(2'd1));
    localparam logic signed [WU-1:0] OFF2 = WU'(-row_sum(2'd2));
    localparam logic signed [WU-1:0] OFF3 = WU'(-row_sum(2'd3));

    // ------------------------------------------------------------------
    // Datapath state
    // ------------------------------------------------------------------
    logic signed [XW-1:0] sh0, sh1, sh2, sh3;   // x shift registers (LSB first)
    logic signed [WU-1:0] u0, u1, u2, u3;       // upper accumulators
    logic        [LW-1:0] l0, l1, l2, l3;       // bits shifted out on the right

    logic [2:0] cnt;      // active-cycle index, 1..7 (cycle 0 is the load cycle)
    logic       active;   // internal FSM-busy register (high during cnt=1..7)

    logic load;           // 1-cycle pulse: sample x, begin cycle 0 (bit 0)
    // Gated on the registered active flag, not on busy (busy depends on
    // load; gating on busy would be a combinational loop).
    assign load = start && !active;
    assign busy = active | load;

    // The sign bit (bit 7) is processed on the LAST cycle in LSB-first order.
    logic last_cycle;
    assign last_cycle = active && (cnt == 3'd7);

    // Current bit of each input: straight from x on the load cycle, from
    // the shift registers afterwards.
    logic b0, b1, b2, b3;
    assign b0 = load ? x0[0] : sh0[0];
    assign b1 = load ? x1[0] : sh1[0];
    assign b2 = load ? x2[0] : sh2[0];
    assign b3 = load ? x3[0] : sh3[0];

    // OBC address (3 bits, shared by all four ROMs): each of inputs 1..3
    // compared against input 0's bit.
    logic [N-2:0] addr;
    assign addr = {~(b3 ^ b0), ~(b2 ^ b0), ~(b1 ^ b0)};

    // Subtract M when b0 is 0 on an ordinary cycle, and when b0 is 1 on
    // the sign-bit cycle (the sign bit carries negative weight).
    logic sub;
    assign sub = ~(b0 ^ last_cycle);

    // ROM lookups and sign extension to the adder width
    logic signed [SW-1:0] rom0, rom1, rom2, rom3;
    assign rom0 = ROM0[addr];
    assign rom1 = ROM1[addr];
    assign rom2 = ROM2[addr];
    assign rom3 = ROM3[addr];

    logic signed [WU-1:0] rom0_ext, rom1_ext, rom2_ext, rom3_ext;
    assign rom0_ext = {{(WU-SW){rom0[SW-1]}}, rom0};
    assign rom1_ext = {{(WU-SW){rom1[SW-1]}}, rom1};
    assign rom2_ext = {{(WU-SW){rom2[SW-1]}}, rom2};
    assign rom3_ext = {{(WU-SW){rom3[SW-1]}}, rom3};

    // On the load cycle the accumulator operand is the row offset (-T)
    // instead of the stale value left from the previous computation.
    logic signed [WU-1:0] uop0, uop1, uop2, uop3;
    assign uop0 = load ? OFF0 : u0;
    assign uop1 = load ? OFF1 : u1;
    assign uop2 = load ? OFF2 : u2;
    assign uop3 = load ? OFF3 : u3;

    // One shared adder/subtractor per row: sum = uop + (sub ? -rom : rom),
    // negation via ~rom + 1 exactly as in the original.
    logic signed [WU-1:0] sum0, sum1, sum2, sum3;
    assign sum0 = uop0 + (sub ? ~rom0_ext : rom0_ext) + {{(WU-1){1'b0}}, sub};
    assign sum1 = uop1 + (sub ? ~rom1_ext : rom1_ext) + {{(WU-1){1'b0}}, sub};
    assign sum2 = uop2 + (sub ? ~rom2_ext : rom2_ext) + {{(WU-1){1'b0}}, sub};
    assign sum3 = uop3 + (sub ? ~rom3_ext : rom3_ext) + {{(WU-1){1'b0}}, sub};

    // ------------------------------------------------------------------
    // Sequential control + datapath update
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            done   <= 1'b0;
            cnt    <= 3'd0;
            sh0 <= '0; sh1 <= '0; sh2 <= '0; sh3 <= '0;
            u0  <= '0; u1  <= '0; u2  <= '0; u3  <= '0;
            l0  <= '0; l1  <= '0; l2  <= '0; l3  <= '0;
        end else begin
            done <= 1'b0;   // default: 1-cycle pulse only

            if (load) begin
                // Cycle 0: bit 0 is consumed straight from x; the shift
                // registers are loaded pre-shifted so bit 1 is next.
                sh0 <= x0 >>> 1;
                sh1 <= x1 >>> 1;
                sh2 <= x2 >>> 1;
                sh3 <= x3 >>> 1;
                u0  <= sum0 >>> 1;
                u1  <= sum1 >>> 1;
                u2  <= sum2 >>> 1;
                u3  <= sum3 >>> 1;
                l0  <= {sum0[0], l0[LW-1:1]};
                l1  <= {sum1[0], l1[LW-1:1]};
                l2  <= {sum2[0], l2[LW-1:1]};
                l3  <= {sum3[0], l3[LW-1:1]};
                cnt    <= 3'd1;
                active <= 1'b1;
            end else if (active) begin
                sh0 <= sh0 >>> 1;
                sh1 <= sh1 >>> 1;
                sh2 <= sh2 >>> 1;
                sh3 <= sh3 >>> 1;
                u0  <= sum0 >>> 1;
                u1  <= sum1 >>> 1;
                u2  <= sum2 >>> 1;
                u3  <= sum3 >>> 1;
                l0  <= {sum0[0], l0[LW-1:1]};
                l1  <= {sum1[0], l1[LW-1:1]};
                l2  <= {sum2[0], l2[LW-1:1]};
                l3  <= {sum3[0], l3[LW-1:1]};

                if (last_cycle) begin
                    active <= 1'b0;
                    done   <= 1'b1;
                end else begin
                    cnt <= cnt + 3'd1;
                end
            end
        end
    end

    // y = {U, L}: the register holds 2*y after 8 cycles with a
    // guaranteed-zero bit dropped, so the low YW bits are y itself.
    assign y0 = {u0[YW-LW-1:0], l0};
    assign y1 = {u1[YW-LW-1:0], l1};
    assign y2 = {u2[YW-LW-1:0], l2};
    assign y3 = {u3[YW-LW-1:0], l3};

endmodule
