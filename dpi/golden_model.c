/*
 * golden_model.c
 *
 * DPI-C golden reference model for the 4x4 signed matrix-vector
 * multiplier: y = A*x, using the same fixed 8-bit signed coefficient
 * matrix A as rtl/da_matvec_mult.sv. Callable from SystemVerilog via
 * DPI-C from both Verilator and Vivado (xsim/xelab).
 *
 * No svdpi.h dependency: the exported function only uses plain scalar
 * arguments (SV `byte` <-> C int8_t, SV `int` <-> C int32_t), which
 * needs no DPI helper types, keeping the include path identical
 * between the two toolchains.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * A_FLAT is pulled in from ../common/matrix_a.inc via #include -- the
 * SAME file rtl/da_matvec_mult.sv pulls in via `include -- so the
 * matrix is written down exactly once for the whole project. Row r,
 * column c is at flat index r*4+c.
 */
static const int32_t A_FLAT[16] = {
#include "../common/matrix_a.inc"
};

void golden_matvec(int8_t x0, int8_t x1, int8_t x2, int8_t x3,
                    int32_t *y0, int32_t *y1, int32_t *y2, int32_t *y3)
{
    int32_t x[4];
    int32_t *y[4];
    int r, c;

    x[0] = x0; x[1] = x1; x[2] = x2; x[3] = x3;
    y[0] = y0; y[1] = y1; y[2] = y2; y[3] = y3;

    for (r = 0; r < 4; r++) {
        int32_t sum = 0;
        for (c = 0; c < 4; c++) {
            sum += A_FLAT[r*4+c] * x[c];
        }
        *y[r] = sum;
    }
}

#ifdef __cplusplus
}
#endif
