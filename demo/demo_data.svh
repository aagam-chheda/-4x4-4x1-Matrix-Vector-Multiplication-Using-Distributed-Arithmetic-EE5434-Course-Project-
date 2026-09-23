// demo_data.svh
//
// Example matrices for demo/demo_tb.sv -- the file this project's true
// per-instance parameterization demo pulls its matrices from. Edit this
// file and re-run `make run` to try different examples; no RTL changes
// needed, since da_matvec_mult's coefficient matrix is a true module
// parameter (A_FLAT, see rtl/da_matvec_mult.sv), not a compile-time
// constant baked into the module body.
//
// DEMO_MAT_REAL is the SAME matrix as common/matrix_a.inc (the actual
// verified hardware's default). It's spelled out explicitly here rather
// than `included from there, so this file stays a fully self-contained,
// readable reference for a presentation -- "here is the matrix, here is
// the file that defines it" -- without needing to explain the
// include-path indirection mid-demo. If you ever change
// common/matrix_a.inc, update the copy here too if you want this demo
// to keep showing the real hardware's actual matrix.
//
// Row r, column c is at flat index r*4+c, same convention as
// common/matrix_a.inc.

localparam int signed DEMO_MAT_REAL [16] = '{
    -128,  127,    3,   -1,
      64,  -64,    0,  127,
     -17,   17, -128,   50,
       1,   -1,    5, -128
};

// Diagonal scaling matrix: y[i] = scale[i] * x[i], nothing else --
// trivially checkable by eye in a live demo.
localparam int signed DEMO_MAT_DIAG [16] = '{
    2, 0, 0, 0,
    0, 3, 0, 0,
    0, 0, 4, 0,
    0, 0, 0, 5
};

// All-ones matrix: every row sums the whole input vector, so all four
// outputs come out identical and equal to sum(x) -- also trivially
// checkable by eye.
localparam int signed DEMO_MAT_ONES [16] = '{
    1, 1, 1, 1,
    1, 1, 1, 1,
    1, 1, 1, 1,
    1, 1, 1, 1
};
