// Self-checking testbench for the Sobel engine (Stage 2b onward).
// Stage 3a: drain time raised from 10 to 30 clocks for the longer pipeline.
// Streams image.hex into the design one pixel at a time, with random idle
// cycles (like a real camera link), and checks every result against
// expected.txt from gen_sobel.py. Also writes what the hardware produced to
// sim_out.hex so show_result.py can turn it into a picture.
`timescale 1ns/1ps
module tb_sobel;
    localparam IMG_W = 96, IMG_H = 64;               // must match gen_sobel.py
    localparam N_IN  = IMG_W * IMG_H;
    localparam N_OUT = (IMG_W - 2) * (IMG_H - 2);
    localparam SUM_W = 20;

    reg               clk = 0, rst = 1;
    reg               in_valid = 0;
    reg  [7:0]        in_pix = 0;
    wire              out_valid;
    wire signed [SUM_W-1:0] out_gx, out_gy;
    wire [7:0]        out_mag;

    sobel #(.IMG_W(IMG_W), .COL_BITS(7), .ROW_BITS(7), .SUM_W(SUM_W)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_pix(in_pix),
        .out_valid(out_valid), .out_gx(out_gx), .out_gy(out_gy), .out_mag(out_mag));

    always #5 clk = ~clk;                             // 100 MHz

    reg [7:0] img [0:N_IN-1];
    integer   i, fexp, fout, n, got = 0, errors = 0;
    reg [31:0] e_gx, e_gy, e_mag;

    // ---------------- checker: runs on every clock ----------------
    always @(posedge clk) begin
        if (out_valid) begin
            n = $fscanf(fexp, "%h %h %h\n", e_gx, e_gy, e_mag);
            $fdisplay(fout, "%02x", out_mag);
            if (n != 3) begin
                errors = errors + 1;
                if (errors <= 10) $display("FAIL: extra output #%0d (expected.txt ran out)", got);
            end else if (out_gx !== e_gx[SUM_W-1:0] || out_gy !== e_gy[SUM_W-1:0] ||
                         out_mag !== e_mag[7:0]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL output #%0d (row %0d, col %0d): gx=%0d gy=%0d mag=%0d  expected gx=%0d gy=%0d mag=%0d",
                             got, got / (IMG_W-2) + 1, got % (IMG_W-2) + 1, out_gx, out_gy, out_mag,
                             $signed(e_gx), $signed(e_gy), e_mag);
            end
            got = got + 1;
        end
    end

    // ---------------- stimulus ----------------
    initial begin
        $readmemh("image.hex", img);
        fexp = $fopen("expected.txt", "r");
        fout = $fopen("sim_out.hex", "w");
        if (fexp == 0) begin $display("ERROR: expected.txt not found"); $finish; end

        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;

        i = 0;
        while (i < N_IN) begin
            @(negedge clk);
            if ($random % 4 == 0) begin               // ~25% of cycles: no pixel this clock
                in_valid = 0;
            end else begin
                in_valid = 1;
                in_pix   = img[i];
                i = i + 1;
            end
        end
        @(negedge clk) in_valid = 0;
        repeat (30) @(posedge clk);                    // let the pipeline drain (Stage 3a: 15-clock latency)

        $fclose(fexp);
        $fclose(fout);
        if (errors == 0 && got == N_OUT)
            $display("PASS: %0d edge pixels matched the golden model", got);
        else
            $display("FAIL: %0d errors, %0d outputs (expected %0d)", errors, got, N_OUT);
        $finish;
    end
endmodule
