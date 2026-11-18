// Stage 3a: streaming Sobel edge detector on the SYSTOLIC convolution engine.
// Changes from Stage 2d:
//   - The two conv3x3 engines are replaced by conv3x3_sys (still programmable:
//     the coefficients come in on a port), which takes 11 clocks instead of 3.
//   - The valid flag now travels through a CONV_LAT-long shift register
//     instead of three hand-written stages. Latency 7 -> 15 clocks.
// Kept from earlier stages: pipelined magnitude (2d), line buffer sized to
// 2^COL_BITS words (2c).
// Pixels arrive one at a time in raster order (left to right, top to bottom),
// the way a camera sends them. Two line buffers remember the previous two
// rows, so every new pixel completes a 3x3 window without storing the frame.
//
// Ports
//   in_valid / in_pix : one 8-bit grayscale pixel when in_valid = 1
//                       (in_valid may drop to 0 at any time; the pipeline waits)
//   out_valid         : 1 when out_gx / out_gy / out_mag hold a new result
//   out_gx, out_gy    : horizontal and vertical gradients (signed)
//   out_mag           : edge strength |gx| + |gy|, clamped to 0..255
//
// Results are produced only for pixels whose full 3x3 neighbourhood is
// inside the image, so a W x H frame gives (W-2) x (H-2) outputs.
// Pulse rst before each frame to restart the row/column counters.
module sobel #(
    parameter IMG_W    = 640,   // pixels per row
    parameter COL_BITS = 10,    // enough bits to count to IMG_W-1
    parameter ROW_BITS = 10,
    parameter SUM_W    = 20
)(
    input  wire                    clk, rst,
    input  wire                    in_valid,
    input  wire [7:0]              in_pix,
    output reg                     out_valid,
    output reg  signed [SUM_W-1:0] out_gx, out_gy,
    output reg  [7:0]              out_mag
);
    // ---------------------------------------------------------------
    // Row / column counters: where in the frame is the incoming pixel?
    // ---------------------------------------------------------------
    reg [COL_BITS-1:0] col;
    reg [ROW_BITS-1:0] row;

    always @(posedge clk) begin
        if (rst) begin
            col <= 0;
            row <= 0;
        end else if (in_valid) begin
            if (col == IMG_W-1) begin
                col <= 0;
                row <= row + 1;
            end else
                col <= col + 1;
        end
    end

    // ---------------------------------------------------------------
    // Line buffer: one 16-bit word per column = {pixel 2 rows up, pixel 1 row up}.
    // Read and write ports are separate, so XST can put this in a block RAM.
    // ---------------------------------------------------------------
    reg [15:0] lb [0:(1<<COL_BITS)-1];     // only the first IMG_W words are used
    reg [15:0] lb_q;                       // word read for the current column

    // Stage 1 registers: the incoming pixel and where it was
    reg                s1_valid;
    reg [7:0]          s1_pix;
    reg [COL_BITS-1:0] s1_col;
    reg [ROW_BITS-1:0] s1_row;

    always @(posedge clk) begin
        if (in_valid)
            lb_q <= lb[col];               // read {2 rows up, 1 row up} for this column
        if (s1_valid)
            lb[s1_col] <= {lb_q[7:0], s1_pix};  // shift the column down one row
    end

    always @(posedge clk) begin
        if (rst) s1_valid <= 0;
        else     s1_valid <= in_valid;
        s1_pix <= in_pix;
        s1_col <= col;
        s1_row <= row;
    end

    // ---------------------------------------------------------------
    // 3x3 window: shift in one new column (top, middle, bottom) per pixel
    // ---------------------------------------------------------------
    reg [7:0] w0, w1, w2,     // top row    (left, centre, right)
              w3, w4, w5,     // middle row
              w6, w7, w8;     // bottom row
    reg       win_valid;

    always @(posedge clk) begin
        if (s1_valid) begin
            w0 <= w1;  w1 <= w2;  w2 <= lb_q[15:8];   // 2 rows up
            w3 <= w4;  w4 <= w5;  w5 <= lb_q[7:0];    // 1 row up
            w6 <= w7;  w7 <= w8;  w8 <= s1_pix;       // current row
        end
        // the window is complete once we are at least 2 rows and 2 columns in
        if (rst) win_valid <= 0;
        else     win_valid <= s1_valid && (s1_row >= 2) && (s1_col >= 2);
    end

    wire [71:0] win = {w8, w7, w6, w5, w4, w3, w2, w1, w0};

    // ---------------------------------------------------------------
    // Two convolutions in parallel: Gx (vertical edges), Gy (horizontal edges)
    //   Gx = -1 0 +1     Gy = -1 -2 -1
    //        -2 0 +2           0  0  0
    //        -1 0 +1          +1 +2 +1
    // Packed k8..k0 (bottom-right first); FF = -1, FE = -2 in two's complement
    // ---------------------------------------------------------------
    localparam [71:0] KX = {8'h01, 8'h00, 8'hFF,  8'h02, 8'h00, 8'hFE,  8'h01, 8'h00, 8'hFF};
    localparam [71:0] KY = {8'h01, 8'h02, 8'h01,  8'h00, 8'h00, 8'h00,  8'hFF, 8'hFE, 8'hFF};

    wire signed [SUM_W-1:0] gx, gy;
    conv3x3_sys #(.SUM_W(SUM_W)) cx (.clk(clk), .win(win), .coef(KX), .sum(gx));
    conv3x3_sys #(.SUM_W(SUM_W)) cy (.clk(clk), .win(win), .coef(KY), .sum(gy));

    // valid flag travels alongside the data through conv3x3_sys's pipeline.
    // CONV_LAT must equal the engine's latency (11 clocks, see conv3x3_sys.v);
    // one clock off and every output is paired with the wrong valid.
    localparam CONV_LAT = 11;
    reg  [CONV_LAT-1:0] v_pipe;
    always @(posedge clk) begin
        if (rst) v_pipe <= 0;
        else     v_pipe <= {v_pipe[CONV_LAT-2:0], win_valid};
    end
    wire v_sum = v_pipe[CONV_LAT-1];    // gx / gy are ready

    // ---------------------------------------------------------------
    // Magnitude: |gx| + |gy|, clamped to 255 so it fits in an 8-bit pixel.
    //
    // Stage 2c did all of this in ONE clock: negate (20-bit carry chain),
    // add (another carry chain), compare, clamp = 4.05 ns, the slowest path.
    // Stage 2d splits it over two clocks:
    //   clock A: absolute values      -> ax_r, ay_r
    //   clock B: add, compare, clamp  -> out_mag
    // gx and gy are delayed one clock too (gx_d, gy_d) so out_gx / out_gy
    // still come out in the same clock as the out_mag they belong to.
    // ---------------------------------------------------------------
    reg        [SUM_W-1:0] ax_r, ay_r;      // |gx|, |gy|
    reg signed [SUM_W-1:0] gx_d, gy_d;      // gx, gy delayed to match
    reg                    v_abs;           // valid for ax_r / ay_r

    // clock A
    always @(posedge clk) begin
        ax_r <= gx[SUM_W-1] ? -gx : gx;
        ay_r <= gy[SUM_W-1] ? -gy : gy;
        gx_d <= gx;
        gy_d <= gy;
        if (rst) v_abs <= 0;
        else     v_abs <= v_sum;
    end

    // clock B
    wire [SUM_W:0] mag = ax_r + ay_r;

    always @(posedge clk) begin
        if (rst) out_valid <= 0;
        else     out_valid <= v_abs;
        out_gx  <= gx_d;
        out_gy  <= gy_d;
        out_mag <= (mag > 255) ? 8'd255 : mag[7:0];
    end
endmodule
