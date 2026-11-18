// Stage 3a: SYSTOLIC 3x3 convolution engine (programmable coefficients).
//
// Same job as conv3x3: sum = p0*k0 + p1*k1 + ... + p8*k8, one window per clock.
// What's different is HOW the 9 products are added.
//
// Why: in Stage 2d the slowest path was one hop between two DSP48E1s. One DSP
// computed (product + partial sum) WITHOUT storing it, and passed the
// unregistered result to the next DSP, which added again and only then stored
// it. Two DSP adders in one clock = 3.70 ns.
//
// The fix is a systolic chain: every tap stores its partial sum (the DSP's P
// register), and the next tap adds its own product to that stored value on
// the NEXT clock:
//
//     tap 0:  P0 <= m0
//     tap 1:  P1 <= P0 + m1        (P0 is from the previous clock)
//     tap 2:  P2 <= P1 + m2
//     ...
//     tap 8:  P8 <= P7 + m8   = the finished sum
//
// Every path is now one multiply OR one add, never more, and the partial sum
// travels between DSPs on their dedicated cascade wires (PCOUT -> PCIN).
//
// The catch: the partial sum reaches tap i exactly i clocks later than it
// reaches tap 0. So pixel i must ALSO be delayed by i clocks, or tap i would
// multiply a pixel from a later window. That's the "skew" delay line in each
// tap (DELAY = i). Getting these delays right is the whole trick of a
// systolic array, and the testbench checks it.
//
// Pipeline, for a window sampled on clock edge c:
//     tap i:  delay line (i clocks) -> a_r, b_r (DSP input regs, AREG/BREG)
//             -> m_r (DSP multiplier reg, MREG) -> pout (DSP output reg, PREG)
//     tap i's pout holds its partial sum after edge c + 2 + i
//     tap 8 (the final sum) after edge c + 10, so LATENCY = 11 clocks
//     (conv3x3 in Stage 2c/2d: 3 clocks)
// Throughput is still one window per clock.
//
// Coefficients are treated as fixed while data is flowing (each tap samples
// its coefficient at a different time). Change coef only when the pipeline
// is idle. Stage 3b loads weights properly.
module conv3x3_sys #(parameter SUM_W = 20)(
    input  wire                     clk,
    input  wire [71:0]              win,    // 9 unsigned 8-bit pixels, p0 = win[7:0]
    input  wire [71:0]              coef,   // 9 signed 8-bit coefficients, k0 = coef[7:0]
    output wire signed [SUM_W-1:0]  sum
);
    localparam N = 9;

    // pc[i] = partial sum coming INTO tap i (pc[0] = 0), pc[N] = final sum
    wire signed [SUM_W-1:0] pc [0:N];
    assign pc[0] = {SUM_W{1'b0}};

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : tap
            sys_tap #(.DELAY(i), .SUM_W(SUM_W)) t (
                .clk  (clk),
                .x    (win [8*i +: 8]),
                .w    (coef[8*i +: 8]),
                .pin  (pc[i]),
                .pout (pc[i+1])
            );
        end
    endgenerate

    assign sum = pc[N];
endmodule


// One tap of the systolic chain: delay the pixel by DELAY clocks, multiply it
// by its coefficient, and add the product to the partial sum from the
// previous tap. Written so XST can put everything after the delay line into
// a single DSP48E1 with all of its pipeline registers turned on.
module sys_tap #(
    parameter DELAY = 0,
    parameter SUM_W = 20
)(
    input  wire                     clk,
    input  wire [7:0]               x,      // unsigned pixel
    input  wire signed [7:0]        w,      // signed coefficient
    input  wire signed [SUM_W-1:0]  pin,    // partial sum from the previous tap
    output reg  signed [SUM_W-1:0]  pout    // partial sum to the next tap
);
    // ---- skew: delay the pixel by DELAY clocks (XST packs this into SRLs) ----
    wire [7:0] xd;
    generate
        if (DELAY == 0) begin : no_delay
            assign xd = x;
        end else begin : delay_line
            reg [7:0] sr [0:DELAY-1];
            integer k;
            always @(posedge clk) begin
                sr[0] <= x;
                for (k = 1; k < DELAY; k = k + 1)
                    sr[k] <= sr[k-1];
            end
            assign xd = sr[DELAY-1];
        end
    endgenerate

    // ---- the DSP part ----
    reg signed [8:0]  a_r;      // pixel with a 0 on top (still 0..255), AREG
    reg signed [7:0]  b_r;      // coefficient, BREG
    reg signed [16:0] m_r;      // product, MREG. The pixel is never negative, so the
                                // product is -32,640..32,385 and would fit in 16 bits;
                                // 17 is the general 9 x 8 width and XST trims the spare bit

    always @(posedge clk) begin
        a_r  <= {1'b0, xd};
        b_r  <= w;
        m_r  <= a_r * b_r;
        pout <= pin + m_r;      // PREG; pin is the previous tap's PREG
    end
endmodule
