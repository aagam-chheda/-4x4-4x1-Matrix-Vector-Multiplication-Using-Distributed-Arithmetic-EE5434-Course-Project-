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
common/ matrix_a.inc        - default matrix A for the verified regression (see below)
rtl/    da_matvec_mult.sv   - synthesizable DUT
dpi/    golden_model.c      - DPI-C golden reference model (y = A*x in C)
tb/     da_matvec_tb.sv     - self-checking testbench + scoreboard
sim/
  verilator/Makefile        - Verilator build/run/coverage flow
  vivado/                   - Vivado xsim batch flow (filelist + Linux/.sh and Windows/.bat scripts)
  xcelium/                  - Cadence Xcelium (xrun) batch flow (filelist + script)
demo/                        - presentation demo: true per-instance matrix
                               parameterization, see "Demo" below
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
  as the *default value* of a module `parameter` (not a `localparam`):
  `parameter int signed A_FLAT [N*N] = '{ ... };`. Making it a real
  parameter (rather than a compile-time-fixed constant) means an
  instance can override it with a completely different matrix --
  `da_matvec_mult #(.A_FLAT(SOME_OTHER_MATRIX)) dut (...)` -- with no
  RTL edit and no rebuild-between-cases, while any instance that doesn't
  override it (every instance in the verified regression,
  `tb/da_matvec_tb.sv` included) still gets exactly this file's matrix,
  unchanged. See "Demo: true per-instance matrix parameterization" below
  for a concrete example -- three instances of this same module, three
  different matrices, one simulation, no rebuild.
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
`xvlog -i ../../common` to point at it.

Turning `A_FLAT` from a `localparam` into a `parameter` (to support the
demo below) is a real change to this verified RTL file, so it was
re-checked against the full regression immediately: the entire
408,425-check suite still passes unchanged on Verilator after the
change, confirming the new parameter's default behaves identically to
the old localparam for every instance that doesn't override it --
exactly the property this change needed to preserve.

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

## Demo: true per-instance matrix parameterization

```sh
cd demo
make run
```

A small, separate, presentation-oriented testbench (`demo/demo_tb.sv`) --
not part of the verified regression, doesn't touch `tb/`, `sim/`, or any
of its build artifacts. It exists purely to show off that `A_FLAT` is now
a real SystemVerilog module `parameter`, not a compile-time-fixed
constant: it instantiates the *exact same* `da_matvec_mult` RTL module
three times in **one** simulation, each instance given a **different**
4x4 matrix via `#(.A_FLAT(...))`, and prints a clean summary of each
case's matrix, input vector, and computed output. No rebuild between
cases -- all three exist side by side in the one compiled, elaborated
design.

Each of the three cases is chosen so the expected result can be checked
by eye, without needing to trust anything:

- **Case 1**: the real hardware's matrix (a copy of `common/matrix_a.inc`
  -- see `demo/demo_data.svh` for why it's a copy rather than a shared
  `include, kept intentionally self-contained for presentation clarity),
  with an arbitrary example vector -- this is the actual verified chip.
- **Case 2**: a diagonal scaling matrix `diag(2,3,4,5)` -- `y[i]` should
  come out to exactly `scale[i]*x[i]`, nothing more.
- **Case 3**: an all-ones matrix -- every row sums the same input vector,
  so all four `y` outputs should be identical and equal to `sum(x)`.

Confirmed output in this environment (Verilator), matching independently
Python-computed expected values for all three cases:

```
Case 1: x=(5,-3,10,-7)   -> y=(-984,-377,-1766,954)
Case 2: x=(10,10,10,10)  -> y=(20,30,40,50)
Case 3: x=(1,2,3,4)      -> y=(10,10,10,10)
```

To try a different example, edit the matrices/vectors in
`demo/demo_data.svh` / `demo/demo_tb.sv` and `make run` again -- no RTL
changes needed, since the matrix is now a genuine parameter of the
already-verified `da_matvec_mult` module. This demo has only been run
under Verilator; the Vivado/Xcelium flows haven't been extended to cover
it (not needed for the verified regression, which is unaffected by any
of this -- see the confirmation below).

## Testbench / verification

The design intent here is adversarial: every test category below was
chosen to target a specific class of bug, not just to demonstrate the
happy path. **Total: 408,425 checks**, all passing (confirmed in this
environment: ~2.2s of actual simulation time under Verilator).

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
- **Exhaustive single-channel sweep** (1,024 = 4 x 256): every signed
  8-bit value on one input channel at a time, others held at 0. Not
  random -- deterministically exhaustive per channel. Exhaustive per
  channel, but *not* per combination -- that gap is closed by the next
  two categories.
- **Exhaustive pairwise sweep** (393,216 = 6 pairs x 256 x 256): every
  one of the 6 unordered pairs of input channels, swept over the full
  256x256 combinations of values on that pair (other two channels held
  at 0). This is the category that actually closes the gap the
  single-channel sweep leaves open: a bug in how one channel's bits map
  to the shared DA address (exactly the class of bug the mutation-testing
  writeup below describes catching only by luck, via the bit-position
  walk) is *guaranteed* to be caught here, not just probabilistically --
  confirmed by re-running that same mutant against the expanded suite:
  337,564 of 408,425 checks fail, tens of thousands of them from the
  pairwise sweep alone for the corrupted channel pair.
- **Exhaustive curated 4-way Cartesian product** (4,096 = 8^4): full
  combinations, all four channels varying at once, over 8 "interesting"
  values (`-128, -127, -1, 0, 1, 64, 65, 127` -- both extremes,
  near-extremes on each side, zero, +/-1, and a non-corner adjacent pair
  to catch carry-propagation-style bugs away from the extremes). Where
  the pairwise sweep guarantees 2-way coverage across the full value
  range, this guarantees full 4-way coverage for the values a bug is
  statistically most likely to hide in.
- **Protocol/handshake invariant monitor**: a separate, always-on
  checker (independent of the scoreboard's output-correctness checks)
  that verifies the DUT's internal timing *contract* holds on literally
  every clock cycle of the entire regression, not just the specific
  cycles the control-robustness tests above happen to probe: `busy` and
  `done` are never simultaneously high; `done` is exactly a 1-cycle
  pulse; `busy` is asserted for exactly 8 consecutive cycles per
  computation (not 7, not 9); and `y0..y3` hold their value from the
  `done` cycle until the next computation's load cycle (the "holds until
  next start" contract from the interface documentation, actually
  checked rather than assumed). Deliberately plain procedural checks
  (not `assert property` with temporal operators) -- SVA support has
  historically been the kind of SystemVerilog feature that varies
  between simulators, and this project already hit two real portability
  surprises with other features this session; plain `always`-block
  checks are the same technique already proven portable against a real
  Verilator + Vivado 2024.2 run.
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
  below) -- triggers `$fatal`. Whether that reliably gives a nonzero
  *process* exit code turns out to be simulator-dependent, confirmed the
  hard way: a standalone `$fatal` test under `verilator --binary` returns
  exit code 1 as expected, but the identical standalone test under Vivado
  2024.2's `xsim -R` returns exit code **0** even though the log correctly
  shows `Fatal: forced failure` -- Vivado's `$fatal` triggers `$finish`
  internally rather than aborting the process. Because of this, none of
  the three simulation wrapper scripts (`sim/verilator/Makefile`,
  `sim/vivado/run_vivado.sh`/`.bat`, `sim/xcelium/run_xcelium.sh`) trust
  the simulator's raw exit code for the actual regression run -- the
  Vivado and Xcelium scripts instead capture the run's log and grep it
  for `REGRESSION PASSED`, setting their own exit code from that
  (Verilator's raw exit code is fine as-is and used directly, since it's
  the one actually confirmed reliable).
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
  report. Result in this environment: 97.0% toggle, 75.0% branch, and
  every RTL line that executes at simulation time covered (12/12 lines
  outside `build_rom()`). The only 0%-hit RTL lines (9 of them) are all
  inside `build_rom()`, the elaboration-time function that constant-folds
  the ROM tables into `localparam`s -- it runs once during compile-time
  elaboration, not during simulation, so it correctly shows no
  simulation-time hits; this is expected, not a coverage hole. On the
  testbench side, the 0%-hit lines are failure-diagnostic branches
  (`$display("FAIL...")`, timeout guards, the new protocol monitor's
  violation-reporting branches) that by construction only execute when
  something is actually broken -- a healthy shape for a report from an
  all-passing run, not a gap.

### Mutation testing: does this suite actually catch bugs?

To check the suite has real bug-catching power rather than just a large
vector count, two mutants were deliberately injected into the RTL,
confirmed to be caught, then reverted (not part of the committed source --
this is a one-time check performed during development):

1. **Reintroduced the historical accumulator-reset bug** (forced
   `acc0_shifted` to always shift the old accumulator, even on the
   sign-bit cycle, for row 0 only). Caught immediately and overwhelmingly:
   407,941/408,425 checks failed against the current, expanded suite
   (11,061/11,113 failed when this was first tried, before the pairwise/
   curated/protocol-monitor categories existed), with `y0` specifically
   wrong while `y1..y3` stayed correct -- confirming the scoreboard's
   per-row comparison catches even a single-row-only corruption, not just
   gross across-the-board breakage.
2. **Swapped the address-bit wiring for input channels 2 and 3** in the
   steady-state (post-cycle-0) address mux -- a "miswired ROM address
   bus" class of bug. This one is instructive: `all-neg128` and
   `all-pos127` (x2 == x3 in both) **did not detect it at all**, since
   swapping which channel feeds which address bit is invisible when both
   channels carry the same value. At the time this was first tried (11,113
   total checks, no pairwise sweep yet), it was caught by the per-channel
   bit-position walk (`bitwalk-ch2-*`, `bitwalk-ch3-*`) and the boundary
   permutations -- which is exactly why those categories were added, but
   it's worth being honest that catching it there was closer to "the
   specific chosen vectors happened to differ between ch2 and ch3" than
   to a structural guarantee. **Re-run against the expanded 408,425-check
   suite** (with the exhaustive pairwise sweep added) for a stronger
   check: 337,564/408,425 checks now fail, tens of thousands of them from
   the ch2/ch3 pairwise sweep alone. That's the actual point of that
   category -- it doesn't just happen to catch this class of bug, it's
   mathematically guaranteed to for any pair of channels, since every one
   of the 65,536 combinations for that pair is checked.

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
- **GNU Make and a POSIX shell (bash).** The Verilator Makefile,
  `sim/vivado/run_vivado.sh`, and `sim/xcelium/run_xcelium.sh` assume
  Linux/macOS/WSL conventions (`rm -rf`, forward-slash paths, etc.) --
  use WSL (or a Linux-native tool install) for those. The one exception
  is `sim/vivado/run_vivado.bat`, a native Windows Command Prompt
  equivalent for a Vivado install that lives on Windows itself rather
  than inside WSL -- see "Running in Vivado" below for when to use which.
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

**Vivado (Windows, 2024.2) is now confirmed working end-to-end, against
the full current suite:** `run_vivado.bat`, run against a real Vivado
install (not in this development environment -- over the course of the
same project, on the user's own machine), passes
`REGRESSION PASSED: 408425/408425 checks passed`, identical to the
Verilator result including the same default seed and pass count --
re-confirmed after the testbench was expanded from 11,113 to 408,425
checks (see "Testbench / verification" above), so this isn't a stale
figure from before that expansion. Getting there surfaced and fixed four
real, simulator-specific issues (a `filelist.f` path-resolution bug, an
`$urandom(seed)` statement-form rejection, a `$fatal`-doesn't-affect-
exit-code quirk, and an unquoted-`-testplusarg` parse failure) -- see
"Running in Vivado" below for the full account. `run_vivado.sh` (the
Linux-native counterpart) carries the same fixes but hasn't itself been
run against a real install.

**Cadence Xcelium (22.09-s003) is now also confirmed working end-to-end,
against the full current suite:** `run_xcelium.sh`, run against a real
Xcelium install on a shared university EDA server, passes
`REGRESSION PASSED: 408425/408425 checks passed`, identical to both the
Verilator and Vivado results including the same default seed and pass
count. Getting there surfaced and fixed one real, Xcelium-specific issue
(`-R` means something different in a one-shot `xrun` invocation than it
does for Vivado's `xsim -R` -- see "Running in Cadence Xcelium" below for
the full account). **All three simulators this project targets are now
genuinely confirmed, on the same expanded suite, not just documented
against.**

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
**408,425/408,425 scoreboard checks pass**, full cycle/control-path/address
coverage (16/16 ROM addresses), exit code 0 on pass / 1 on any injected
failure (see "Mutation testing" above).

The random regression uses a fixed default seed for reproducible runs; to
try a different random sequence, pass `+SEED=<n>` directly to the built
binary:

```sh
./obj_dir/Vda_matvec_tb +SEED=1234
```

## Running in Vivado (xsim, batch/non-project mode)

There are two entry points, and which one to use depends on *where Vivado
is actually installed*, not where the repo happens to be checked out:

- **`run_vivado.sh`** -- for a Linux-native Vivado install (including one
  installed directly inside WSL's Linux filesystem). Run from bash:
  ```sh
  cd sim/vivado
  ./run_vivado.sh
  ```
- **`run_vivado.bat`** -- for a Vivado install on Windows itself (the
  common case when working from WSL, since Vivado on Windows is a
  separate install from anything inside the WSL distro, and its
  `xvlog`/`xelab`/`xsim`/`xsc` are Windows binaries that don't run under
  WSL bash). Run from a **native Windows shell** -- either the
  "Vivado \<version\> Tcl Shell" shortcut Vivado's installer creates, or an
  ordinary Command Prompt/PowerShell after running
  `call C:\Xilinx\Vivado\<version>\settings64.bat` -- **not** from WSL
  bash:
  ```bat
  cd sim\vivado
  run_vivado.bat
  ```
  For this case, clone the repo directly onto the Windows filesystem
  (e.g. `C:\Users\<you>\...`) rather than pointing the Windows Vivado
  tools at the WSL-side checkout through `\\wsl$\...` -- that network
  path works but is slower and occasionally flaky for heavy build I/O.

Both scripts run the same sequence: `xsc` (compiles `golden_model.c` to a
DPI-C shared library), `xvlog --sv` (compiles the RTL + testbench from
`filelist.f`), `xelab -sv_lib` (elaborates and links the DPI library), and
`xsim -R` (batch-mode run). To override the regression's random seed,
pass it as a plain positional argument to either script:
```sh
./run_vivado.sh 1234
```
```bat
run_vivado.bat 1234
```
Internally, this becomes `xsim da_matvec_tb_sim -R -testplusarg "SEED=1234"`
-- confirmed the hard way that the *quoting* matters here: forwarding an
unquoted `-testplusarg SEED=1234` through (which is what an earlier
version of these scripts did, generically passing through `"$@"`/`%*`)
fails with `Expected a switch but found 1`; the value has to be quoted
(`-testplusarg "SEED=1234"`) for `xsim` to parse it correctly. Both
scripts now build that quoted form internally instead of asking the
caller to get Vivado's specific quoting right themselves.

Both scripts run directly from `sim/vivado/` rather than `cd`-ing into a
work subdirectory first: `filelist.f`'s paths (`../../rtl/...`,
`../../tb/...`) are relative to `sim/vivado/`, and Xilinx's `xvlog`
resolves a `-f` file's contents relative to the directory `xvlog` is
*invoked from*, not relative to the `-f` file's own location. An earlier
version of this script did `cd` into a work subdirectory first, which
broke that resolution one directory level short -- caught on a real first
run against Vivado 2024.2 (Windows): `xsc` succeeded, but `xvlog` then
failed with `Can not find file: ../../rtl/da_matvec_mult.sv`. Fixed by not
relocating the working directory; Xilinx's own build artifacts
(`xsim.dir/`, `.Xil/`, `golden_model.a`) are left in `sim/vivado/` and
gitignored instead.

### Confirmed: full pass on real Vivado 2024.2 (Windows)

`run_vivado.bat` has been run to completion against a real Vivado 2024.2
install on Windows, via WSL for the git side and a native Windows Command
Prompt for Vivado itself (see the note above about why: Vivado's tools
are Windows binaries and don't run under WSL bash). Two confirmed runs
over the course of this project, as the testbench grew:

- Against the original 11,113-check suite:
  **`REGRESSION PASSED: 11113/11113 checks passed`**.
- Against the current, expanded 408,425-check suite (see "Testbench /
  verification" above for what was added -- the exhaustive pairwise/
  curated-4-way sweeps and the protocol monitor):
  **`REGRESSION PASSED: 408425/408425 checks passed`**, ~15s of actual
  `run:` time per xsim's own reported stats.

Both runs are identical to the corresponding Verilator result, including
reproducing the exact same default seed (`14311149`) and getting the
exact same pass count from it, which is itself a good sanity check that
the DPI golden model and the RTL behave identically under both
simulators, and that the expanded testbench's new categories (pairwise
sweep, curated 4-way, protocol monitor) hold up on Vivado too, not just
Verilator.

Getting there surfaced four real, simulator-specific issues, each now
fixed in the committed source (not worked around by disabling anything):

1. **The `filelist.f` path-resolution bug** described above (`xvlog`
   resolves relative to the invocation directory, not the `-f` file's own
   location) -- `xsc` succeeded first (confirming, contrary to an earlier
   guess in this README, that Vivado's bundled MinGW gcc handles the
   DPI-C compile fine on Windows with **no** separate MSVC/Visual Studio
   install needed), then `xvlog` failed with
   `Can not find file: ../../rtl/da_matvec_mult.sv`.
2. **`void'($urandom(seed));`**, used once at the top of the testbench to
   deterministically seed the CRV regression, was rejected by `xelab`
   with `urandom system task is not supported` -- Vivado's xsim doesn't
   accept `$urandom(seed)` called as a bare statement (`void'`-cast or
   not). The IEEE-designated alternative, `$srandom(seed);`, turned out
   to have the opposite problem: this Verilator build doesn't implement
   it at all (`Unsupported or unknown PLI call`). Fixed by assigning the
   return value to a genuine (otherwise-unused) variable instead of
   discarding it via a bare statement -- unambiguously a function-call
   expression, which both tools accept.
3. **`xsim -R`'s own process exit code doesn't reflect `$fatal`** -- see
   the exit-code note in "Testbench / verification" above. Fixed in both
   `run_vivado.sh` and `run_vivado.bat` by grepping the run's own log for
   `REGRESSION PASSED` and setting the script's exit code from that,
   rather than trusting `xsim`'s.
4. **`-testplusarg SEED=1234` forwarded unquoted fails**: an earlier
   version of both scripts generically forwarded any extra CLI arguments
   straight through to `xsim` (`"$@"`/`%*`), matching the Verilator/
   Xcelium convention of a bare `+SEED=1234`. Under Vivado, forwarding
   `-testplusarg SEED=1234` that way failed with
   `Expected a switch but found 1`; the value needs to be quoted
   (`-testplusarg "SEED=1234"`) for `xsim` to parse it. Fixed by having
   both scripts take the seed as a plain positional argument
   (`./run_vivado.sh 1234` / `run_vivado.bat 1234`) and build the
   correctly-quoted `xsim` invocation internally, rather than asking the
   caller to get Vivado's specific quoting right.

`run_vivado.sh` (the Linux-native path) has *not* itself been run against
a real Vivado install -- only `run_vivado.bat` (Windows) has -- but it's
the same sequence of commands with the same fixes applied, so the
remaining risk there is narrower than before. Two points still worth
double-checking if you hit something on that path specifically:

- **`build_rom()`**: an `automatic` function with bounded `for` loops,
  returning an unpacked array type, called with a constant argument at
  `localparam` elaboration time. Standard IEEE-1800, and confirmed
  working under both Verilator and Vivado 2024.2's `xvlog`/`xelab` (no
  errors or warnings about it in the real Vivado run above) -- low risk
  at this point, but the mechanical fallback (an explicit 16-entry `case`
  statement per row) still applies if a different Vivado version ever
  rejects it.
- **Async reset (`rst_n`, active-low, asynchronous)**: used throughout;
  standard synthesizable style, and the real Vivado run above exercised
  it correctly (including the mid-computation-reset robustness test),
  but flagged here since reset-style conventions can differ across FPGA
  sign-off flows if this RTL is ever pushed through actual synthesis.

## Running in Cadence Xcelium

```sh
cd sim/xcelium
./run_xcelium.sh                # default (fixed) seed
./run_xcelium.sh +SEED=1234     # override the CRV seed for a fresh sequence
```

`xrun` must already be on `PATH` -- that's site-specific (a `module load
xcelium` or sourcing a setup script on a shared EDA server) and outside
this repo's control. The script runs a single `xrun` invocation that
compiles, elaborates, and runs in one step:

```sh
xrun -sv -access +rwc -top da_matvec_tb \
     -incdir ../../common -f filelist.f \
     ../../dpi/golden_model.c \
     -xmlibdirname xcelium_work/xcelium.d \
     -l xcelium_work/xrun.log "$@"
```

then greps `xcelium_work/xrun.log` for `REGRESSION PASSED` and sets its
own exit code from that, rather than trusting `xrun`'s own exit code --
see the note below on why.

- `-incdir ../../common` gives `` `include "matrix_a.inc" `` a search path
  to resolve against, the same role `-I` plays for Verilator and `-i`
  plays for `xvlog` in the Vivado flow.
- `golden_model.c` is passed straight to `xrun` alongside the SV sources;
  Xcelium compiles and links C/C++ DPI sources given on its command line
  directly, without a separate shared-library-build step (unlike Vivado's
  `xsc` + `xelab -sv_lib`) -- the `extern "C"` guard already in
  `dpi/golden_model.c` (added for Verilator's C++-compiled-DPI behavior)
  keeps this path safe either way.
- No explicit run-control flag is needed for the one-shot flow: `xrun`
  compiles, elaborates, and runs to completion by default when given HDL
  sources directly on the command line. **Confirmed the hard way against
  a real Xcelium 22.09-s003 run that `-R` here is actively wrong**, not
  just unnecessary -- `-R` in this context means "skip straight to
  running a previously-elaborated snapshot" (a separate 2-phase
  workflow), not "run to completion after elaborating" the way Vivado's
  `xsim -R` does. Combined with HDL sources and `-top` in the same
  invocation, `xrun` warned `-TOP with -R option will be ignored` /
  `HDL source files with -R option will be ignored`, then failed with
  `NOSTUP` since no snapshot existed yet. Any extra arguments the script
  is called with (e.g. `+SEED=1234`) are forwarded straight through to
  the simulation as plusargs, same convention as the Verilator binary.
- The testbench's RNG-reseed line (`seed_reseed_unused = $urandom(seed);`)
  was reworked based on a real Vivado-specific rejection of the original
  `void'($urandom(seed));` form (see "Running in Vivado" below) -- since
  the fix lives in the shared `tb/da_matvec_tb.sv`, not a per-simulator
  script, Xcelium gets the more portable form automatically, whatever its
  own stance on the original form would have been.

### Confirmed: full pass on real Xcelium 22.09-s003

`run_xcelium.sh` has been run to completion against a real Xcelium
22.09-s003 install (a shared university EDA server, via `xrun` at
`/home/Cadence_tools/XCELIUM2209/tools/bin/xrun` on that machine -- not
on `PATH` by default there, just not wired into `module`/a login shell).
Result: **`REGRESSION PASSED: 408425/408425 checks passed`**, all 8
cycles/both control paths/16 ROM addresses covered -- identical to both
the Verilator and Vivado results, including the same default seed
(`14311149`) and the same pass count on the full current suite. All
three simulators this project targets are now genuinely confirmed
end-to-end against the same 408,425-check regression, not just two of
three plus documentation for the third.

Getting there surfaced one real, Xcelium-specific issue, described above
and now fixed in the committed source: **`-R` in a one-shot `xrun`
invocation means "skip straight to running a previously-elaborated
snapshot,"** not "run to completion after elaborating" the way Vivado's
`xsim -R` does -- combined with HDL sources and `-top` in the same
command, it warned that both would be ignored, then failed with `NOSTUP`
since no snapshot existed yet. Dropping `-R` entirely fixed it: `xrun`
compiles, elaborates, and runs to completion by default when given HDL
sources directly, with no separate run-control flag needed.

Two harmless, informational warnings appeared in the log and don't
affect correctness:
- `xmelab: *W,DSEMEL` / `xmsim: *W,DSEM2009` -- simulated per IEEE
  1800-2009 semantics by default; not an issue for this design.
- `xmsim: *W,OLDURR` -- Xcelium's default `$urandom_range` algorithm "can
  have distribution problems." Since the CRV bias logic is already
  explicitly engineered (30% extreme/near-extreme literals, 20% boundary
  jitter, 50% uniform -- see "Testbench / verification" above) rather
  than relying on `$urandom_range` alone for interesting-value coverage,
  and the actual pass/fail check is exact equality against the golden
  model regardless of how the random stream was generated, this doesn't
  affect correctness here -- but worth knowing about if this testbench
  is ever reused somewhere sample-distribution-quality matters more.

`$fatal`/exit-code propagation from `xrun` was not separately isolated
with a standalone test the way it was for Vivado (the full regression's
own log-grep-based exit code was confirmed correct instead, which is
what actually matters for CI use) -- `run_xcelium.sh` still doesn't
trust `xrun`'s raw exit code, on principle, regardless.

If you hit an actual error running this in a different Xcelium version,
the fastest way to get help debugging it (from me, without an Xcelium
install to reproduce against) is the exact `xrun` error text plus the
surrounding lines of `xcelium_work/xrun.log` -- SystemVerilog semantics
can be reasoned about from the error message even without the tool in
hand.

## Interface

```systemverilog
module da_matvec_mult #(
    parameter int N  = 4,
    parameter int XW = 8,   // input width
    parameter int YW = 18,  // output width
    parameter int RW = 10,  // ROM entry width

    // Coefficient matrix, flat row-major (row r, col c at A_FLAT[r*N+c]).
    // Default pulled from common/matrix_a.inc; override per instance for
    // a different matrix with no rebuild -- see demo/demo_tb.sv.
    parameter int signed A_FLAT [N*N] = '{ /* from common/matrix_a.inc */ }
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
