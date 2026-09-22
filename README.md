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

The matrix `A` is written down in exactly one place --
[`common/matrix_a.inc`](common/matrix_a.inc) -- and pulled into both the RTL
and the golden model at compile time (see "Single source of truth for A"
below). Edit it there; nothing else needs to change.

## Directory layout

```
common/ matrix_a.inc        - single source of truth for matrix A (see below)
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

### Single source of truth for A

`A` needs to be written down twice: once as ROM source data for the RTL,
once as the reference computation in the golden model. Keeping those two
copies in sync by hand would be a real risk (a typo in one and not the
other would silently weaken the whole verification setup, since the
scoreboard would then be comparing two *different* matrices instead of two
independent implementations of the *same* one). Instead, both files pull
the values from one place, [`common/matrix_a.inc`](common/matrix_a.inc): a
flat, row-major list of 16 signed integer literals with no
language-specific syntax around it.

- `rtl/da_matvec_mult.sv` pulls it in with SystemVerilog's `` `include ``
  into `localparam int signed A_FLAT [16] = '{ ... };`
- `dpi/golden_model.c` pulls it in with C's `#include` into
  `static const int32_t A_FLAT[16] = { ... };`

Both are plain textual-substitution preprocessor directives, so the same
file is valid, unmodified, inside either language's initializer-list
syntax. Editing `common/matrix_a.inc` and rebuilding is all that's needed
for the change to reach both the DA ROMs and the golden model -- verified
in this environment by swapping in an unrelated test matrix, rebuilding,
and confirming the regression still passes 5005/5005 against the *new*
values (both sides picked it up), then restoring the original matrix and
confirming a clean 5005/5005 pass again.

One portability wrinkle: unlike C's `#include "..."`, which searches
relative to the including source file by default, SystemVerilog's
`` `include `` is resolved against the tool's `-I`/`-i` search path. So the
RTL uses a bare filename (`` `include "matrix_a.inc" ``), and
`sim/verilator/Makefile` passes `-I../../common` / `run_vivado.sh` passes
`xvlog -i ../../../common` to point at it.

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

The design intent here is adversarial: every test category below was
chosen to target a specific class of bug, not just to demonstrate the
happy path. **Total: 11,113 checks**, all passing.

- **Golden model** (`dpi/golden_model.c`): plain C, `y = A*x` for signed
  8-bit inputs against the same constant `A`. No `svdpi.h` dependency (the
  exported function only uses scalar `byte`/`int` DPI types), and the
  function body is wrapped in `extern "C" { ... }` guarded by
  `#ifdef __cplusplus` -- Verilator compiles DPI `.c` sources with a C++
  compiler by default, which name-mangles a plain C function unless it's
  marked `extern "C"`; this keeps the same source portable to a C-compiled
  Vivado `xsc` flow too. Every single check below (directed and random)
  gets its expected value live from this model -- there is no hardcoded
  expected output anywhere in the testbench.
- **Hand-picked directed edge cases** (5): all-zero, all-(-128),
  all-(+127), a mixed-sign vector, and a near-worst-case-magnitude vector
  (signs aligned to maximize row 0's output magnitude for this specific
  `A`, ~33022 -- see the note in "Architecture" above about why this isn't
  the generic 65536 bound).
- **Back-to-back accumulator-reset regression** (6): the exact class of
  sequence (repeated/complementary vectors, no idle gap) that caught the
  historical accumulator-reset bug during bring-up (see below) -- kept as
  an explicit, labeled regression test rather than relying only on
  incidental back-to-back timing elsewhere in the suite.
- **Per-channel bit-position walk** (32): each of the 8 bit weights
  (1, 2, 4, 8, 16, 32, 64, -128) applied to one input channel at a time,
  others held at 0. Targets bit-order/shift-register/Horner-weighting bugs
  that a random vector might only trigger by chance. This category is not
  theoretical: see "Mutation testing" below, where it's exactly what
  caught an injected channel-address-swap bug that the original
  all-same-value directed tests completely missed.
- **Hypercube corners** (16): every combination of the two most extreme
  values (-128/127) across all four inputs.
- **Alternating-bit-pattern vectors** (2): `0x55`/`0xAA` and its rotation.
- **Boundary-value permutations** (24): all 4! permutations of
  `(127, -128, 126, -127)` across the four input slots.
- **Control/handshake robustness** (3 scenarios, not textbook sequences):
  `start` held high for an entire computation (confirms the FSM ignores
  it while `active`, and that dropping it exactly at `done` prevents an
  auto-retrigger); a spurious one-cycle `start` pulse with *different*
  data injected mid-computation (confirms the in-flight result is
  unaffected); an async `rst_n` injected mid-computation (confirms
  `busy`/`done` cleanly deassert and a following computation still
  produces a correct, golden-model-checked result).
- **Exhaustive single-channel sweep** (1024 = 4 x 256): every signed
  8-bit value on one input channel at a time, others held at 0. Not
  random -- deterministically exhaustive per channel.
- **Constrained-random regression** (10,000): each element drawn with a
  3-tier bias -- 30% from an exact/near-extreme literal set
  (`-128,-127,-126,127,126,125,-1,0,1,2,-2`), 20% "boundary jitter" (a
  random 0-6 offset inward from one of the two rails, to stress values
  *adjacent to* the extremes, not just the extremes themselves), and 50%
  full uniform for broad exploration; additionally, 10% of the 10,000
  vectors force all four elements to the same extreme value. Deterministic
  by default (fixed seed `0xDA5EED`) for reproducible CI runs -- pass
  `+SEED=<n>` (e.g. `./obj_dir/Vda_matvec_tb +SEED=1234`) to explore a
  fresh sequence. Confirmed passing in this environment against the
  default seed and several explicit overrides (`+SEED=1`, `+SEED=42`,
  `+SEED=999999`).
- **Scoreboard**: on every `done` pulse, compares all four DUT outputs
  against the DPI golden model for the same inputs, tallies pass/fail, and
  prints a final summary. Any mismatch -- or incomplete coverage (see
  below) -- triggers `$fatal`, which gives a nonzero process exit code for
  CI use (verified in this environment: a standalone `$fatal` test under
  `verilator --binary` returns exit code 1).
- **Cycle/control-path/address coverage**: rather than depend on
  simulator-specific functional-coverage tooling (which could behave
  differently between Verilator and Vivado), the testbench directly
  tracks, via hierarchical reference into the DUT (`dut.load`, `dut.cnt`,
  `dut.sub`, `dut.addr`, `dut.busy`), which of the 8 shift cycles, which
  of the two adder/subtractor control paths (`sub=1` on cycle 0, `sub=0`
  on cycles 1-7), and which of the 16 possible DA ROM addresses were
  exercised across the whole regression, failing the run if any are
  missing. Confirmed hit in this environment: all 8 cycles, both control
  paths, and all 16/16 ROM addresses.
- Additionally, `make coverage` under `sim/verilator/` runs a Verilator
  `--coverage` (line/toggle/branch) build for a supplementary quantitative
  report. Result in this environment: 96.6% toggle, 75.9% branch, 100%
  line coverage on every RTL line that executes at simulation time. The
  only 0%-hit RTL lines are inside `build_rom()`, the elaboration-time
  function that constant-folds the ROM tables into `localparam`s -- it
  runs once during compile-time elaboration, not during simulation, so it
  correctly shows no simulation-time hits; this is expected, not a
  coverage hole. On the testbench side, the only 0%-hit lines are
  failure-diagnostic branches (`$display("FAIL...")`, timeout guards) that
  by construction only execute when something is actually broken -- a
  healthy shape for a report from an all-passing run, not a gap.

### Mutation testing: does this suite actually catch bugs?

To check the suite has real bug-catching power rather than just a large
vector count, two mutants were deliberately injected into the RTL,
confirmed to be caught, then reverted (not part of the committed source --
this is a one-time check performed during development):

1. **Reintroduced the historical accumulator-reset bug** (forced
   `acc0_shifted` to always shift the old accumulator, even on the
   sign-bit cycle, for row 0 only). Caught immediately: 11,061/11,113
   checks failed, starting from the third directed test, with `y0`
   specifically wrong while `y1..y3` stayed correct -- confirming the
   scoreboard's per-row comparison catches even a single-row-only
   corruption, not just gross across-the-board breakage.
2. **Swapped the address-bit wiring for input channels 2 and 3** in the
   steady-state (post-cycle-0) address mux -- a "miswired ROM address
   bus" class of bug. This one is instructive: `all-neg128` and
   `all-pos127` (x2 == x3 in both) **did not detect it at all**, since
   swapping which channel feeds which address bit is invisible when both
   channels carry the same value. It was caught immediately by the
   per-channel bit-position walk (`bitwalk-ch2-*`, `bitwalk-ch3-*`) and
   the boundary permutations, which is exactly why those categories were
   added -- a test suite built only from same-value corner cases would
   have shipped this bug silently.

## Portability / requirements

Nothing in the repo hardcodes a path, username, or machine-specific
setting (checked with `grep` across all sources -- clean -- and by
cloning the repo into an unrelated directory and running the full
regression from there, which reproduced the same 11,113/11,113 pass).
The Verilator flow is otherwise plain SystemVerilog/C -- what actually
needs to be present on another machine:

- **Verilator >= 5.002.** This repo relies on `--timing` (for the
  testbench's `@(negedge clk)` inside tasks/loops) and `--binary` (so
  Verilator generates the C++ main itself). Both were introduced
  together in Verilator's first v5 release, 5.002 (2022-10-29) -- so any
  reasonably current Verilator install qualifies, not just a bleeding-edge
  one. Concretely: this repo was built and verified here against
  `5.053 devel` (a git snapshot build); Ubuntu's own package repo
  currently ships `5.032-1` via `apt install verilator`, comfortably
  above the minimum. Not independently tested against an older/different
  installed version in this environment, but nothing used here is newer
  than the 2022 baseline.
- **A C++20-capable g++ or clang++.** Verilator's `--timing` feature
  itself requires C++20 (per Verilator's own release notes) for the code
  it generates and compiles. GCC 10+ / Clang 10+ or newer should be fine;
  verified here with GCC 15.2.0.
- **GNU Make and a POSIX shell (bash).** The Verilator Makefile and
  `sim/vivado/run_vivado.sh` assume Linux/macOS/WSL conventions
  (`rm -rf`, forward-slash paths, etc.). Not adapted for native Windows
  `cmd`/PowerShell -- use WSL there.
- **`git` and `gh`** only if you want to reproduce the clone/push flow
  used to stand this repo up; not needed just to build and simulate.

One thing that is *not* a repo dependency, but could confuse a first
build on a different machine: this environment's Verilator install
happens to route its generated C++ compile through `ccache` (visible in
the `make run` build log as `ccache g++ ...`). That comes from how
*this particular* Verilator binary was built/configured, not from
anything in this project's Makefile -- a different Verilator install
without `ccache` available will just call `g++` directly and build fine
either way.

**Vivado (xsim) is the one genuinely unverified piece.** There is no
Vivado install in this development environment, so `sim/vivado/run_vivado.sh`
has never actually been run (see the "Running in Vivado" section below
for the specific points to double-check -- DPI-C via `xsc`, the
`build_rom()` elaboration pattern, and exit-code propagation from
`$fatal`). Everything else in this repo -- RTL, testbench, golden model,
Verilator flow -- has been directly built and run, repeatedly, in this
environment, including from a from-scratch clone in an unrelated
directory.

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
**11,113/11,113 scoreboard checks pass**, full cycle/control-path/address
coverage (16/16 ROM addresses), exit code 0 on pass / 1 on any injected
failure (see "Mutation testing" above).

The random regression uses a fixed default seed for reproducible runs; to
try a different random sequence, pass `+SEED=<n>` directly to the built
binary:

```sh
./obj_dir/Vda_matvec_tb +SEED=1234
```

## Running in Vivado (xsim, batch/non-project mode)

```sh
cd sim/vivado
./run_vivado.sh
```

This runs, in order: `xsc` (compiles `golden_model.c` to a DPI-C shared
library), `xvlog --sv` (compiles the RTL + testbench from `filelist.f`),
`xelab -sv_lib` (elaborates and links the DPI library), and `xsim -R`
(batch-mode run). To override the regression's random seed under xsim,
pass the plusarg on the `xsim` command line (documented Xilinx xsim
syntax; not exercised here since there's no Vivado install to test
against): `xsim da_matvec_tb_sim -R -testplusarg SEED=1234`.

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
