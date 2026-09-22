// da_matvec_mult.sv
//
// 4x4 signed matrix-vector multiplier using bit-serial Distributed Arithmetic (DA).
// Computes y = A*x where A is a fixed 4x4 signed 8-bit constant matrix and x is
// a 4-element signed 8-bit input vector. Outputs are 18-bit signed.
//
// Algorithm:
//   For each output row r: y[r] = sum_i A[r][i] * x[i]
//   Each x[i] is two's complement: x[i] = -b_i7*2^7 + sum_{k=0}^{6} b_ik * 2^k
//   => y[r] = -2^7 * ROM_r(addr(bit7)) + sum_{k=0}^{6} 2^k * ROM_r(addr(bit_k))
//   where ROM_r(addr) is the subset sum of row r's coefficients selected by addr.
//
// This is evaluated MSB-first via Horner's rule over 8 cycles:
//   cycle 0 (sign bit):      acc <= -ROM_r(addr)
//   cycles 1..7 (bit6..bit0): acc <= (acc << 1) + ROM_r(addr)
//
// The negate-on-cycle-0 / add-on-later-cycles is implemented with a single shared
// adder/subtractor per row: acc_next = (acc<<1) + (sub ? ~rom : rom) + sub
// (sub=1 on cycle 0 gives ~rom+1 = -rom via two's complement identity).

`timescale 1ns/1ps

module da_matvec_mult #(
    parameter int N  = 4,   // vector/matrix dimension
    parameter int XW = 8,   // input element width (signed)
    parameter int YW = 18,  // output element width (signed)
    parameter int RW = 10   // ROM entry width (signed) - subset sums fit in 9 bits,
                             // 10 gives headroom
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

    // ------------------------------------------------------------------
    // Fixed coefficient matrix (compile-time constant)
    // ------------------------------------------------------------------
    localparam int signed A_MAT [N][N] = '{
        '{-128,  127,    3,   -1},
        '{  64,  -64,    0,  127},
        '{ -17,   17, -128,   50},
        '{   1,   -1,    5, -128}
    };

    // ------------------------------------------------------------------
    // DA ROM generation: for each row, a 16-entry table of subset sums.
    // ROM[row][addr] = sum over i of (addr[i] ? A_MAT[row][i] : 0)
    //
    // NOTE (Verilator/Vivado portability): this uses an automatic function
    // returning an unpacked array, invoked at elaboration time with a
    // constant `row` argument, to build a localparam lookup table. This is
    // standard IEEE-1800 (functions with bounded for-loops, constant
    // folding into a localparam) and is supported by both Verilator and
    // Vivado's synthesizer/xsim/xelab. If a specific Vivado version rejects
    // it, the fallback is to replace each ROM with an explicit case
    // statement (mechanically equivalent, see README).
    // ------------------------------------------------------------------
    typedef logic signed [RW-1:0] rom_t [2**N];

    function automatic rom_t build_rom(input logic [$clog2(N)-1:0] row);
        rom_t r;
        int sum;
        for (int addr = 0; addr < 2**N; addr++) begin
            sum = 0;
            for (int i = 0; i < N; i++) begin
                if (addr[i]) sum += A_MAT[row][i];
            end
            r[addr] = RW'(sum);
        end
        return r;
    endfunction

    localparam rom_t ROM0 = build_rom(2'd0);
    localparam rom_t ROM1 = build_rom(2'd1);
    localparam rom_t ROM2 = build_rom(2'd2);
    localparam rom_t ROM3 = build_rom(2'd3);

    // ------------------------------------------------------------------
    // Datapath state
    // ------------------------------------------------------------------
    logic signed [XW-1:0] sh0, sh1, sh2, sh3;   // shift registers holding x
    logic signed [YW-1:0] acc0, acc1, acc2, acc3;

    logic [2:0] cnt;      // active-cycle index, 1..7 (cycle 0 is the "load" cycle)
    logic       active;   // internal FSM-busy register (high during cnt=1..7)

    logic load;            // 1-cycle pulse: sample x, begin cycle 0 (sign bit)
    // NOTE: gated on the registered `active` flag, not the combinational
    // `busy` output below -- gating on `busy` here would make `busy`
    // depend on `load` and `load` depend on `busy`, a combinational loop
    // with no stable solution when active=0 && start=1 (busy = NOT busy).
    assign load = start && !active;

    // busy is asserted combinationally on the same cycle as `load`, and stays
    // high through the last accumulate cycle (8 cycles total: load + cnt 1..7).
    assign busy = active | load;

    // 4-bit DA address, shared by all four ROMs: one bit per input, MSB-first.
    logic [N-1:0] addr;
    assign addr = load ? {x3[XW-1], x2[XW-1], x1[XW-1], x0[XW-1]}
                        : {sh3[XW-1], sh2[XW-1], sh1[XW-1], sh0[XW-1]};

    logic sub;
    assign sub = load;   // subtract only on cycle 0 (the sign-bit cycle)

    logic last_cycle;
    assign last_cycle = active && (cnt == 3'd7);

    // ROM lookups (combinational reads of the constant tables above)
    logic signed [RW-1:0] rom0, rom1, rom2, rom3;
    assign rom0 = ROM0[addr];
    assign rom1 = ROM1[addr];
    assign rom2 = ROM2[addr];
    assign rom3 = ROM3[addr];

    // Sign-extended ROM operands
    logic signed [YW-1:0] rom0_ext, rom1_ext, rom2_ext, rom3_ext;
    assign rom0_ext = {{(YW-RW){rom0[RW-1]}}, rom0};
    assign rom1_ext = {{(YW-RW){rom1[RW-1]}}, rom1};
    assign rom2_ext = {{(YW-RW){rom2[RW-1]}}, rom2};
    assign rom3_ext = {{(YW-RW){rom3[RW-1]}}, rom3};

    // Shared adder/subtractor per row (one hardware adder, no separate
    // negation logic): acc_next = (acc<<1) + (sub ? ~rom : rom) + sub
    //
    // On cycle 0 (sub=1), the "acc<<1" term is forced to zero rather than
    // carrying in whatever acc held from the *previous* computation --
    // Horner's rule starts each row's accumulation from 0 on the sign-bit
    // cycle. This still uses the one shared adder/subtractor (no separate
    // negation hardware): only the left operand is muxed between the
    // shifted accumulator and zero.
    logic signed [YW-1:0] acc0_shifted, acc1_shifted, acc2_shifted, acc3_shifted;
    assign acc0_shifted = sub ? '0 : (acc0 <<< 1);
    assign acc1_shifted = sub ? '0 : (acc1 <<< 1);
    assign acc2_shifted = sub ? '0 : (acc2 <<< 1);
    assign acc3_shifted = sub ? '0 : (acc3 <<< 1);

    logic signed [YW-1:0] acc0_next, acc1_next, acc2_next, acc3_next;
    assign acc0_next = acc0_shifted + (sub ? ~rom0_ext : rom0_ext) + {{(YW-1){1'b0}}, sub};
    assign acc1_next = acc1_shifted + (sub ? ~rom1_ext : rom1_ext) + {{(YW-1){1'b0}}, sub};
    assign acc2_next = acc2_shifted + (sub ? ~rom2_ext : rom2_ext) + {{(YW-1){1'b0}}, sub};
    assign acc3_next = acc3_shifted + (sub ? ~rom3_ext : rom3_ext) + {{(YW-1){1'b0}}, sub};

    // ------------------------------------------------------------------
    // Sequential control + datapath update
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            done   <= 1'b0;
            cnt    <= 3'd0;
            sh0    <= '0;
            sh1    <= '0;
            sh2    <= '0;
            sh3    <= '0;
            acc0   <= '0;
            acc1   <= '0;
            acc2   <= '0;
            acc3   <= '0;
        end else begin
            done <= 1'b0;   // default: 1-cycle pulse only

            if (load) begin
                // Cycle 0: consume sign bit from x directly, load shift
                // registers pre-shifted by one so bit6 is at the MSB next.
                sh0  <= x0 <<< 1;
                sh1  <= x1 <<< 1;
                sh2  <= x2 <<< 1;
                sh3  <= x3 <<< 1;
                acc0 <= acc0_next;
                acc1 <= acc1_next;
                acc2 <= acc2_next;
                acc3 <= acc3_next;
                cnt    <= 3'd1;
                active <= 1'b1;
            end else if (active) begin
                sh0  <= sh0 <<< 1;
                sh1  <= sh1 <<< 1;
                sh2  <= sh2 <<< 1;
                sh3  <= sh3 <<< 1;
                acc0 <= acc0_next;
                acc1 <= acc1_next;
                acc2 <= acc2_next;
                acc3 <= acc3_next;

                if (last_cycle) begin
                    active <= 1'b0;
                    done   <= 1'b1;
                end else begin
                    cnt <= cnt + 3'd1;
                end
            end
        end
    end

    assign y0 = acc0;
    assign y1 = acc1;
    assign y2 = acc2;
    assign y3 = acc3;

endmodule
