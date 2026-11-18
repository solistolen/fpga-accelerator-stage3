// Self-checking testbench for the Stage 3b feature extractor.
// Loads both weight banks from weights.hex through the weight port, streams
// image.hex in with random idle clocks, sets in_bank per pixel the same way as
// bank_of() in gen_features.py (bank B from SWITCH_ROW down, and in a box of
// rows that switches mid-row and back at each row end, never pausing the
// stream), and checks all 4 filter outputs of every pixel
// against features_expected.txt from gen_features.py. Writes what the
// hardware produced to sim_features.hex for show_features.py.
`timescale 1ns/1ps
module tb_feature_stream;
    localparam IMG_W = 96, IMG_H = 64;
    localparam SWITCH_ROW = 32, BOX_ROW0 = 8, BOX_ROW1 = 15, BOX_COL = 48;   // must match gen_features.py
    localparam N_IN  = IMG_W * IMG_H;
    localparam N_OUT = (IMG_W - 2) * (IMG_H - 2);
    localparam N_F = 4, SUM_W = 20, N_W = N_F * 9;

    reg                  clk = 0, rst = 1;
    reg                  in_valid = 0, in_bank = 0;
    reg  [7:0]           in_pix = 0;
    reg                  w_we = 0, w_bank = 0;
    reg  [5:0]           w_addr = 0;
    reg  [7:0]           w_data = 0;
    wire                 out_valid;
    wire [N_F*SUM_W-1:0] out_f;

    feature_stream #(.IMG_W(IMG_W), .COL_BITS(7), .ROW_BITS(7), .N_F(N_F), .SUM_W(SUM_W)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_pix(in_pix), .in_bank(in_bank),
        .w_we(w_we), .w_bank(w_bank), .w_addr(w_addr), .w_data(w_data),
        .out_valid(out_valid), .out_f(out_f));

    always #5 clk = ~clk;

    reg [7:0]  img [0:N_IN-1];
    reg [7:0]  wts [0:2*N_W-1];
    reg [31:0] e [0:N_F-1];
    integer    i, k, fexp, fout, n, got = 0, errors = 0;

    // ---------------- checker ----------------
    always @(posedge clk) begin
        if (out_valid) begin
            n = $fscanf(fexp, "%h %h %h %h\n", e[0], e[1], e[2], e[3]);
            $fdisplay(fout, "%05x %05x %05x %05x", out_f[19:0], out_f[39:20], out_f[59:40], out_f[79:60]);
            if (n != 4) begin
                errors = errors + 1;
                if (errors <= 10) $display("FAIL: extra output #%0d", got);
            end else
                for (k = 0; k < N_F; k = k + 1)
                    if (out_f[k*SUM_W +: SUM_W] !== e[k][SUM_W-1:0]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("FAIL output #%0d (row %0d, col %0d) filter %0d: got %0d expected %0d",
                                     got, got / (IMG_W-2) + 1, got % (IMG_W-2) + 1, k,
                                     $signed(out_f[k*SUM_W +: SUM_W]), $signed(e[k]));
                    end
            got = got + 1;
        end
    end

    // ---------------- stimulus ----------------
    initial begin
        $readmemh("image.hex", img);
        $readmemh("weights.hex", wts);
        fexp = $fopen("features_expected.txt", "r");
        fout = $fopen("sim_features.hex", "w");
        if (fexp == 0) begin $display("ERROR: features_expected.txt not found"); $finish; end

        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;

        // load bank A then bank B through the weight port
        for (i = 0; i < 2*N_W; i = i + 1) begin
            @(negedge clk);
            w_we = 1; w_bank = (i >= N_W); w_addr = i % N_W; w_data = wts[i];
        end
        @(negedge clk) w_we = 0;

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
        repeat (30) @(posedge clk);

        $fclose(fexp);
        $fclose(fout);
        if (errors == 0 && got == N_OUT)
            $display("PASS: %0d pixels x %0d filters matched the golden model (with mid-frame and mid-row bank switches)",
                     got, N_F);
        else
            $display("FAIL: %0d errors, %0d outputs (expected %0d)", errors, got, N_OUT);
        $finish;
    end
endmodule
