// Unit testbench for the Stage 3a systolic engine (conv3x3_sys).
// Self-checking, no data files needed.
//
// Feeds random 3x3 windows through several coefficient sets (Sobel, the
// int8 extremes, and random weights) and checks every output against a
// reference sum computed right here when the window goes in. ~25% of clocks
// carry no window, like a camera link pausing.
//
// The coefficients only change while the engine is idle (see conv3x3_sys.v),
// so after each coefficient change the test waits for the pipeline to empty.
`timescale 1ns/1ps
module tb_conv_sys;
    localparam SUM_W = 20;
    localparam LAT   = 11;          // conv3x3_sys latency in clocks
    localparam N_RANDOM_SETS = 20;
    localparam WINDOWS_PER_SET = 300;

    reg                     clk = 0;
    reg  [71:0]             win  = 0;
    reg  [71:0]             coef = 0;
    wire signed [SUM_W-1:0] sum;

    conv3x3_sys #(.SUM_W(SUM_W)) dut (.clk(clk), .win(win), .coef(coef), .sum(sum));

    always #5 clk = ~clk;

    // ---------------- reference model ----------------
    function signed [31:0] ref_sum(input [71:0] w, input [71:0] k);
        integer i;
        begin
            ref_sum = 0;
            for (i = 0; i < 9; i = i + 1)
                ref_sum = ref_sum + $signed({1'b0, w[8*i +: 8]}) * $signed(k[8*i +: 8]);
        end
    endfunction

    // expected value and valid flag travel down a shift register as long as the DUT's pipeline
    reg              in_valid = 0;
    reg              v_sr   [0:LAT-1];
    reg signed [31:0] e_sr  [0:LAT-1];
    integer j, checked = 0, errors = 0;

    initial for (j = 0; j < LAT; j = j + 1) begin v_sr[j] = 0; e_sr[j] = 0; end

    always @(posedge clk) begin
        // compare: the output that leaves the DUT now belongs to the window
        // that went in LAT clocks ago
        if (v_sr[LAT-1]) begin
            if (sum !== e_sr[LAT-1][SUM_W-1:0]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("FAIL check #%0d: sum=%0d expected=%0d", checked, sum, e_sr[LAT-1]);
            end
            checked = checked + 1;
        end
        for (j = LAT-1; j > 0; j = j - 1) begin
            v_sr[j] <= v_sr[j-1];
            e_sr[j] <= e_sr[j-1];
        end
        v_sr[0] <= in_valid;
        e_sr[0] <= ref_sum(win, coef);
    end

    // ---------------- stimulus helpers ----------------
    function [71:0] rand_bytes(input dummy);
        integer i;
        begin
            for (i = 0; i < 9; i = i + 1) rand_bytes[8*i +: 8] = $random;
        end
    endfunction

    task idle(input integer n);
        integer t;
        begin
            for (t = 0; t < n; t = t + 1) begin @(negedge clk); in_valid = 0; end
        end
    endtask

    // n windows: mostly random pixels, sometimes all 0 or all 255 (extremes)
    task run_windows(input integer n);
        integer t, r;
        begin
            t = 0;
            while (t < n) begin
                @(negedge clk);
                if ($random % 4 == 0) in_valid = 0;
                else begin
                    r = $random & 15;
                    if (r == 0)      win = {9{8'hFF}};
                    else if (r == 1) win = {9{8'h00}};
                    else             win = rand_bytes(0);
                    in_valid = 1;
                    t = t + 1;
                end
            end
        end
    endtask

    task use_coef(input [71:0] k);
        begin
            idle(LAT + 2);              // let the pipeline empty first
            @(negedge clk); coef = k; in_valid = 0;
            idle(LAT + 2);              // let every tap pick up the new coefficients
        end
    endtask

    integer s;
    initial begin
        // Sobel Gx and Gy (packed k8..k0, same as sobel.v)
        use_coef({8'h01, 8'h00, 8'hFF, 8'h02, 8'h00, 8'hFE, 8'h01, 8'h00, 8'hFF}); run_windows(WINDOWS_PER_SET);
        use_coef({8'h01, 8'h02, 8'h01, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFE, 8'hFF}); run_windows(WINDOWS_PER_SET);
        // int8 extremes: largest negative and positive sums (255 * -128 * 9 = -293,760)
        use_coef({9{8'h80}}); run_windows(WINDOWS_PER_SET);
        use_coef({9{8'h7F}}); run_windows(WINDOWS_PER_SET);
        // different coefficient in every tap, so a wrong skew mixes up taps
        use_coef({8'h09, 8'h08, 8'h07, 8'h06, 8'h05, 8'h04, 8'h03, 8'h02, 8'h01}); run_windows(WINDOWS_PER_SET);
        for (s = 0; s < N_RANDOM_SETS; s = s + 1) begin
            use_coef(rand_bytes(0)); run_windows(WINDOWS_PER_SET);
        end
        idle(LAT + 5);

        if (errors == 0 && checked > 0)
            $display("PASS: %0d windows matched the reference (latency %0d)", checked, LAT);
        else
            $display("FAIL: %0d errors in %0d checks", errors, checked);
        $finish;
    end
endmodule
