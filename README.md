# 4x4 Distributed-Arithmetic Matrix-Vector Multiplier

Computes `y = A*x` for a fixed, compile-time-constant 4x4 signed 8-bit matrix
`A` and a 4-element signed 8-bit input vector `x`, using classic bit-serial
Distributed Arithmetic (DA). Outputs are 18-bit signed.

```
A = [ -128,  127,    3,   -1
        64,  -64,    0,  127
       -17,   17, -128,   50
         1,   -1,    5, -128 ]
```

## Directory layout

```
rtl/    da_matvec_mult.sv   - synthesizable DUT
dpi/    golden_model.c      - DPI-C golden reference model (y = A*x in C)
tb/     da_matvec_tb.sv     - self-checking testbench + scoreboard
sim/
  verilator/Makefile        - Verilator build/run/coverage flow
  vivado/                   - Vivado xsim batch flow (filelist + script)
```

## Architecture

For each output row `r`: `y[r] = sum_i A[r][i] * x[i]`.

Each `x[i]` is two's complement 8-bit:
`x[i] = -b_i7*2^7 + sum_{k=0}^{6} b_ik * 2^k`.

Substituting and regrouping by bit position gives, per row, a 16-entry ROM
of *subset sums* of that row's four coefficients (one ROM address bit per
input, at a given bit position):

```
ROM_r[addr] = sum_i ( addr[i] ? A[r][i] : 0 )   // addr is 4 bits, one per input
```

and the row result is then the bit-serial (MSB-first) Horner evaluation

```
cycle 0 (sign bit, bit 7):  acc <- -ROM_r[addr(bit7)]
cycles 1..7 (bit6..bit0):   acc <- (acc << 1) + ROM_r[addr(bit_k)]
```

which is exactly `y[r]` after 8 cycles. `x` is loaded into four 8-bit shift
registers and shifted out MSB-first, one bit per input per cycle, so the
same 4-bit address feeds all four (one per row) ROMs every cycle -- four
ROMs total, 8 cycles, one shared adder/subtractor per row.

**Shared adder/subtractor, no separate negation hardware:** each row's
accumulate step is `acc_next = shifted_acc + (sub ? ~rom : rom) + sub`, where
`shifted_acc` is `(acc << 1)` on cycles 1-7 and forced to `0` on cycle 0 (see
"design bug found & fixed" below), and `sub` is `1` only on cycle 0. Two's
complement identity `~rom + 1 = -rom` means cycle 0 naturally computes
`-ROM[addr]` and later cycles compute ordinary addition, through one adder.

ROM entries are 10 bits signed (subset sums fit in 9 bits; 10 gives
headroom) and are sign-extended before feeding the shared adder. Accumulators
and outputs are 18 bits signed -- sized from the generic bound of 4 terms x
(-128)x(-128) = 65536 in magnitude (note: for *this specific* matrix `A`,
the actual reachable worst case is smaller, ~33022 on row 0; see the
`near-worst-case-magnitude` directed test in the testbench. The 65536 figure
is a conservative sizing bound, not a value `A` can actually produce -- this
README says so explicitly rather than silently implying otherwise).

### Handshake

- `start` (1-cycle pulse) loads `x0..x3` into the shift registers and begins
  an 8-cycle computation.
- `busy` is high for those 8 cycles (asserted combinationally the same cycle
  as `start`, via `busy = active | load` where `active` is the registered
  FSM-busy state for cycles 1-7 and `load` is the combinational cycle-0
  pulse).
- `done` is a single-cycle pulse the cycle after the last accumulate,
  confirming all four `y` outputs are simultaneously stable.
- `y0..y3` are wired directly from the accumulator registers (no extra
  output register stage) -- they hold the last valid result until the next
  `start`, since the accumulate-and-shift logic is disabled whenever
  `busy` is low. No handshake issue results from skipping an output
  register: `done` already tells the receiver exactly which cycle the
  (already-stable) accumulator value became valid, so an extra register
  would only add a cycle of latency without adding safety.

### Design bug found & fixed during verification

The very first Verilator run passed only the post-reset `all-zero` case and
failed everything after it. Root cause: `acc_next = (acc<<1) + ...` was
literally carrying the *previous* computation's final accumulator value into
the new cycle-0 (sign-bit) step, instead of starting each row's Horner
evaluation from 0. Fixed by forcing the `(acc<<1)` term to `0` specifically
on cycle 0 (`sub=1`), still through the one shared adder -- only the left
operand of the adder is muxed between `acc<<1` and `0`, so there is still no
separate negation/reset hardware. This is exactly the kind of correctness
bug the DPI-C golden-model self-checking scoreboard was built to catch, and
it did, on the very first regression run.

## Testbench / verification

- **Golden model** (`dpi/golden_model.c`): plain C, `y = A*x` for signed
  8-bit inputs against the same constant `A`. No `svdpi.h` dependency (the
  exported function only uses scalar `byte`/`int` DPI types), and the
  function body is wrapped in `extern "C" { ... }` guarded by
  `#ifdef __cplusplus` -- Verilator compiles DPI `.c` sources with a C++
  compiler by default, which name-mangles a plain C function unless it's
  marked `extern "C"`; this keeps the same source portable to a C-compiled
  Vivado `xsc` flow too.
- **Directed tests**: all-zero, all-(-128), all-(+127), a hand-picked
  mixed-sign vector, and a near-worst-case-magnitude vector (signs aligned
  to maximize row 0's output magnitude for this specific `A`).
- **Random regression**: 5000 signed 8-bit vectors. Each element is drawn
  40% of the time from a small extreme-value set
  (`-128,-127,127,126,-1,0,1`) and 60% of the time uniformly from the full
  8-bit signed range; additionally, 10% of the 5000 vectors force all four
  elements to the same extreme value, to stress the all-same-sign worst-case
  pattern explicitly.
- **Scoreboard**: on every `done` pulse, compares all four DUT outputs
  against the DPI golden model for the same inputs, tallies pass/fail, and
  prints a final summary. Any mismatch -- or incomplete cycle/control-path
  coverage (see below) -- triggers `$fatal`, which gives a nonzero process
  exit code for CI use (verified in this environment: a standalone `$fatal`
  test under `verilator --binary` returns exit code 1).
- **Cycle/control-path coverage**: rather than depend on simulator-specific
  functional-coverage tooling (which could behave differently between
  Verilator and Vivado), the testbench directly tracks, via hierarchical
  reference into the DUT (`dut.load`, `dut.cnt`, `dut.sub`, `dut.busy`),
  which of the 8 shift cycles and which of the two adder/subtractor control
  paths (`sub=1` on cycle 0, `sub=0` on cycles 1-7) were exercised across
  the whole regression, and fails the run if any are missing. Confirmed hit
  in this environment: all 8 cycles and both control paths.
- Additionally, `make coverage` under `sim/verilator/` runs a Verilator
  `--coverage` (line/toggle/branch) build for a supplementary quantitative
  report. Result in this environment: 97.7% toggle, 82.4% branch, 100% line
  coverage on every line that executes at simulation time. The only 0%-hit
  lines are inside `build_rom()`, the elaboration-time function that
  constant-folds the ROM tables into `localparam`s -- it runs once during
  compile-time elaboration, not during simulation, so it correctly shows no
  simulation-time hits; this is expected, not a coverage hole.

## Running in Verilator

```sh
cd sim/verilator
make run          # build (if needed) and run the full regression
make coverage      # build with --coverage, run, and annotate line/toggle/branch coverage
make clean
```

`make run` builds `da_matvec_mult.sv` + `da_matvec_tb.sv` + `golden_model.c`
with `verilator --binary --timing`, which lets Verilator auto-generate the
C++ main and drive `$finish`/`$fatal` directly -- no hand-written C++
harness needed. Confirmed working in this environment (Verilator 5.053):
5005/5005 scoreboard checks pass, full cycle/control-path coverage, exit
code 0 on pass / 1 on any injected failure.

## Running in Vivado (xsim, batch/non-project mode)

```sh
cd sim/vivado
./run_vivado.sh
```

This runs, in order: `xsc` (compiles `golden_model.c` to a DPI-C shared
library), `xvlog --sv` (compiles the RTL + testbench from `filelist.f`),
`xelab -sv_lib` (elaborates and links the DPI library), and `xsim -R`
(batch-mode run).

**This has not been run against a real Vivado install in this
environment** (Vivado is not installed here) -- functional sign-off here
was done exclusively with Verilator. Before treating a Vivado run as
sign-off, double-check:

- **DPI-C via `xsc`**: Vivado's `xsc` utility is documented to build DPI-C
  shared libraries for xsim and is the standard mechanism (confirmed
  adequate per Xilinx documentation), but hasn't been exercised here. If it
  rejects the DPI-C source or linking for any reason, the fallback is a
  pre-generated stimulus/expected-result file (e.g. a CSV of `x` vectors and
  golden `y` vectors produced by compiling+running `dpi/golden_model.c`
  standalone, read into the testbench with `$readmemh`/`$fscanf` instead of
  a live DPI call) -- not implemented here since it wasn't needed for the
  Verilator flow, but straightforward to add if `xsc` proves unusable.
- **`$fatal`/exit-code propagation from `xsim -R`**: assumed to behave like
  other simulators (nonzero process exit on `$fatal`), but not verified
  against a real Vivado install.
- **`build_rom()`**: an `automatic` function with bounded `for` loops,
  returning an unpacked array type, called with a constant argument at
  `localparam` elaboration time. Standard IEEE-1800, and supported by
  Verilator (verified here), but if a specific Vivado synthesis/xelab
  version rejects it, the mechanical fallback is to replace each
  `localparam rom_t ROMn = build_rom(n);` with an explicit 16-entry `case`
  statement per row (same subset-sum values, just spelled out instead of
  computed) -- the values are already documented by the algorithm section
  above and can be regenerated by running `build_rom()` logic by hand or via
  the golden model.
- **Async reset (`rst_n`, active-low, asynchronous)**: used throughout;
  standard synthesizable style in both tools for a small register-only
  design, but flagged here since reset-style conventions can differ across
  FPGA sign-off flows.

## Interface

```systemverilog
module da_matvec_mult #(
    parameter int N  = 4,
    parameter int XW = 8,   // input width
    parameter int YW = 18,  // output width
    parameter int RW = 10   // ROM entry width
) (
    input  logic                 clk,
    input  logic                 rst_n,   // async active-low
    input  logic                 start,
    input  logic signed [XW-1:0] x0, x1, x2, x3,
    output logic                 busy,
    output logic                 done,
    output logic signed [YW-1:0] y0, y1, y2, y3
);
```
