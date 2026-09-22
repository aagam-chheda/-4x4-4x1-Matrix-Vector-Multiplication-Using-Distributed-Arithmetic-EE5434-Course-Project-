/*
 * matrix_a.inc
 *
 * SINGLE SOURCE OF TRUTH for the fixed 4x4 signed 8-bit coefficient
 * matrix A used by both the RTL and the golden reference model.
 *
 * This is a flat, row-major list of 16 signed integer literals -- no
 * surrounding braces, no language-specific syntax -- so it can be
 * textually pulled in by both:
 *   - rtl/da_matvec_mult.sv, via SystemVerilog's `include, into
 *     `localparam int signed A_FLAT [16] = '{ ... };`
 *   - dpi/golden_model.c, via C's #include, into
 *     `static const int32_t A_FLAT[16] = { ... };`
 *
 * Both are plain textual-substitution preprocessor directives (SV's
 * backtick-include works the same way as C's #include), so this file
 * has no per-language syntax of its own -- it is valid, unmodified,
 * inside both an SV `'{...}` unpacked-array literal and a C `{...}`
 * initializer list.
 *
 * Row r, column c is at flat index r*4+c. Edit the values here and
 * both the RTL's DA ROMs and the golden model pick it up automatically
 * on the next build -- there is nothing else to keep in sync.
 */
  -128,  127,    3,   -1,
    64,  -64,    0,  127,
   -17,   17, -128,   50,
     1,   -1,    5, -128
