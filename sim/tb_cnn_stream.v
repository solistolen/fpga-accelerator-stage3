// Self-checking testbench for the Stage 3c CNN layer (cnn_stream).
// Loads weights.hex through the weight port and quant.hex through the requant
// parameter port, streams image.hex with random idle clocks and the same
// per-pixel bank pattern as Stage 3b (mid-frame and mid-row switches), and
// checks the 4 output bytes of every pixel against cnn_expected.txt from
// gen_cnn.py. Writes the hardware's output to sim_cnn.hex for show_cnn.py.
`timescale 1ns/1ps
module tb_cnn_stream;
    localparam IMG_W = 96, IMG_H = 64;
    localparam SWITCH_ROW = 32, BOX_ROW0 = 8, BOX_ROW1 = 15, BOX_COL = 48;   // must match gen_features.py
    localparam N_IN  = IMG_W * IMG_H;
    localparam N_OUT = (IMG_W - 2) * (IMG_H - 2);
    localparam N_F = 4, SUM_W = 20, N_W = N_F * 9;

    reg                 clk = 0, rst = 1;
    reg                 in_valid = 0, in_bank = 0;
    reg  [7:0]          in_pix = 0;
    reg                 w_we = 0, w_bank = 0;
    reg  [5:0]          w_addr = 0;
    reg  [7:0]          w_data = 0;
    reg                 q_we = 0, q_bank = 0;
    reg  [1:0]          q_filt = 0;
    reg  [SUM_W-1:0]    q_bias = 0;
    reg  [15:0]         q_mult = 0;
    reg  [4:0]          q_shift = 0;
    wire                out_valid;
    wire [N_F*8-1:0]    out_q;

    cnn_stream #(.IMG_W(IMG_W), .COL_BITS(7), .ROW_BITS(7), .N_F(N_F), .SUM_W(SUM_W)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_pix(in_pix), .in_bank(in_bank),
        .w_we(w_we), .w_bank(w_bank), .w_addr(w_addr), .w_data(w_data),
        .q_we(q_we), .q_bank(q_bank), .q_filt(q_filt), .q_bias(q_bias), .q_mult(q_mult), .q_shift(q_shift),
        .out_valid(out_valid), .out_q(out_q));

    always #5 clk = ~clk;

    reg [7:0]  img [0:N_IN-1];
    reg [7:0]  wts [0:2*N_W-1];
    reg [31:0] e [0:N_F-1];
    reg [31:0] qb, qm, qs;
    integer    i, k, fq, fexp, fout, n, got = 0, errors = 0;

    // ---------------- checker ----------------
    always @(posedge clk) begin
        if (out_valid) begin
            n = $fscanf(fexp, "%h %h %h %h\n", e[0], e[1], e[2], e[3]);
            $fdisplay(fout, "%02x %02x %02x %02x", out_q[7:0], out_q[15:8], out_q[23:16], out_q[31:24]);
            if (n != 4) begin
                errors = errors + 1;
                if (errors <= 10) $display("FAIL: extra output #%0d", got);
            end else
                for (k = 0; k < N_F; k = k + 1)
                    if (out_q[8*k +: 8] !== e[k][7:0]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("FAIL output #%0d (row %0d, col %0d) filter %0d: got %0d expected %0d",
                                     got, got / (IMG_W-2) + 1, got % (IMG_W-2) + 1, k, out_q[8*k +: 8], e[k]);
                    end
            got = got + 1;
        end
    end

    // ---------------- stimulus ----------------
    initial begin
        $readmemh("image.hex", img);
        $readmemh("weights.hex", wts);
        fq   = $fopen("quant.hex", "r");
        fexp = $fopen("cnn_expected.txt", "r");
        fout = $fopen("sim_cnn.hex", "w");
        if (fq == 0 || fexp == 0) begin $display("ERROR: quant.hex or cnn_expected.txt not found"); $finish; end

        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;

        // weights: bank A then bank B
        for (i = 0; i < 2*N_W; i = i + 1) begin
            @(negedge clk);
            w_we = 1; w_bank = (i >= N_W); w_addr = i % N_W; w_data = wts[i];
        end
        @(negedge clk) w_we = 0;

        // requant parameters: bank A filters 0-3, then bank B
        for (i = 0; i < 2*N_F; i = i + 1) begin
            n = $fscanf(fq, "%h %h %h\n", qb, qm, qs);
            @(negedge clk);
            q_we = 1; q_bank = (i >= N_F); q_filt = i % N_F;
            q_bias = qb[SUM_W-1:0]; q_mult = qm[15:0]; q_shift = qs[4:0];
        end
        @(negedge clk) q_we = 0;
        $fclose(fq);

        // stream the frame, switching banks per pixel with no pauses
        i = 0;
        while (i < N_IN) begin
            @(negedge clk);
            if ($random % 4 == 0) begin
                in_valid = 0;
            end else begin
                in_valid = 1;
                in_pix   = img[i];
                in_bank  = (i / IMG_W) >= SWITCH_ROW ||
                           ((i / IMG_W) >= BOX_ROW0 && (i / IMG_W) <= BOX_ROW1 && (i % IMG_W) >= BOX_COL);
                i = i + 1;
            end
        end
        @(negedge clk) in_valid = 0;
        repeat (40) @(posedge clk);                       // 19-clock pipeline

        $fclose(fexp);
        $fclose(fout);
        if (errors == 0 && got == N_OUT)
            $display("PASS: %0d pixels x %0d filters matched the golden model (8-bit outputs after bias, ReLU, requantization)",
                     got, N_F);
        else
            $display("FAIL: %0d errors, %0d outputs (expected %0d)", errors, got, N_OUT);
        $finish;
    end
endmodule
