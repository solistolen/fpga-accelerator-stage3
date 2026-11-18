// Unit testbench for the Stage 3c requant stage (bias, ReLU, scale, round, saturate).
// Self-checking, no data files needed.
//
// - sums: random over the FULL 20-bit signed range, plus the extremes;
// - parameters: random, plus edge cases: shift 0 and 31, mult 0 and 65535,
//   the most negative and most positive bias;
// - banks switch while sums keep streaming, and the idle bank is rewritten
//   live, like the weights in Stage 3b;
// - every output is checked against a reference that does the same integer
//   math in 64 bits.
`timescale 1ns/1ps
module tb_requant;
    localparam N_F = 4, SUM_W = 20, LAT = 6;
    localparam N_CYCLES = 20000;

    reg                  clk = 0, rst = 1;
    reg                  in_valid = 0, in_bank = 0;
    reg  [N_F*SUM_W-1:0] sums = 0;
    reg                  q_we = 0, q_bank = 0;
    reg  [1:0]           q_filt = 0;
    reg  [SUM_W-1:0]     q_bias = 0;
    reg  [15:0]          q_mult = 0;
    reg  [4:0]           q_shift = 0;
    wire                 out_valid;
    wire [N_F*8-1:0]     out_q;

    requant #(.N_F(N_F), .SUM_W(SUM_W)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_bank(in_bank), .sums(sums),
        .q_we(q_we), .q_bank(q_bank), .q_filt(q_filt), .q_bias(q_bias), .q_mult(q_mult), .q_shift(q_shift),
        .out_valid(out_valid), .out_q(out_q));

    always #5 clk = ~clk;

    // ---------------- reference ----------------
    reg signed [SUM_W-1:0] rbias [0:1][0:N_F-1];
    reg        [15:0]      rmult [0:1][0:N_F-1];
    reg        [4:0]       rsh   [0:1][0:N_F-1];

    function [7:0] ref_q(input signed [SUM_W-1:0] sum, input b, input integer flt);
        reg signed [63:0] s;
        reg        [63:0] p;
        begin
            s = sum + rbias[b][flt];
            if (s < 0) s = 0;
            p = s * rmult[b][flt];
            if (rsh[b][flt] != 0) p = p + (64'd1 << (rsh[b][flt] - 1));
            p = p >> rsh[b][flt];
            ref_q = (p > 255) ? 8'd255 : p[7:0];
        end
    endfunction

    reg              v_sr [0:LAT-1];
    reg [N_F*8-1:0]  e_sr [0:LAT-1];
    reg [N_F*8-1:0]  e_now;
    integer j, flt, checked = 0, errors = 0, n_zero = 0, n_sat = 0, n_mid = 0;

    initial for (j = 0; j < LAT; j = j + 1) begin v_sr[j] = 0; e_sr[j] = 0; end

    always @(posedge clk) begin
        if (!rst && v_sr[LAT-1] !== out_valid) begin
            errors = errors + 1;
            if (errors <= 10) $display("FAIL: out_valid=%b, expected %b", out_valid, v_sr[LAT-1]);
        end
        if (v_sr[LAT-1]) begin
            for (flt = 0; flt < N_F; flt = flt + 1) begin
                if (out_q[8*flt +: 8] !== e_sr[LAT-1][8*flt +: 8]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("FAIL output #%0d filter %0d: got %0d expected %0d",
                                 checked, flt, out_q[8*flt +: 8], e_sr[LAT-1][8*flt +: 8]);
                end
                // coverage: how often each output region is hit
                if (e_sr[LAT-1][8*flt +: 8] == 0)        n_zero = n_zero + 1;
                else if (e_sr[LAT-1][8*flt +: 8] == 255) n_sat  = n_sat + 1;
                else                                      n_mid  = n_mid + 1;
            end
            checked = checked + 1;
        end
        for (flt = 0; flt < N_F; flt = flt + 1)
            e_now[8*flt +: 8] = ref_q(sums[flt*SUM_W +: SUM_W], in_bank, flt);
        for (j = LAT-1; j > 0; j = j - 1) begin
            v_sr[j] <= v_sr[j-1];
            e_sr[j] <= e_sr[j-1];
        end
        v_sr[0] <= in_valid & ~rst;
        e_sr[0] <= e_now;
        // mirror the parameter write (after computing e_now: the DUT reads old values this edge)
        if (q_we) begin
            rbias[q_bank][q_filt] = q_bias;
            rmult[q_bank][q_filt] = q_mult;
            rsh  [q_bank][q_filt] = q_shift;
        end
    end

    // ---------------- stimulus ----------------
    function [SUM_W-1:0] rand_sum(input dummy);
        integer r;
        begin
            r = $random & 15;
            case (r)
                0: rand_sum = {1'b1, {(SUM_W-1){1'b0}}};    // most negative
                1: rand_sum = {1'b0, {(SUM_W-1){1'b1}}};    // most positive
                2: rand_sum = 0;
                3, 4, 5: rand_sum = $random % 2048;         // small values: where rounding matters
                default: rand_sum = $random;
            endcase
        end
    endfunction

    // one filter's parameters: a mix of typical and extreme values
    task rand_params(output [SUM_W-1:0] b, output [15:0] m, output [4:0] h);
        integer r;
        begin
            r = $random & 7;
            b = (r == 0) ? {1'b1, {(SUM_W-1){1'b0}}} : (r == 1) ? {1'b0, {(SUM_W-1){1'b1}}} : ($random % 4096);
            r = $random & 7;
            m = (r == 0) ? 16'd0 : (r == 1) ? 16'hFFFF : $random;
            r = $random & 7;
            h = (r == 0) ? 5'd0 : (r == 1) ? 5'd31 : (12 + ($random & 15));   // mostly 12..27: useful scales
        end
    endtask

    integer ld, cyc, since_switch, rw_f, switches = 0, rewrites = 0;
    reg     rw_active, fresh;
    reg [SUM_W-1:0] pb; reg [15:0] pm; reg [4:0] ph;

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;
        // load both banks
        for (ld = 0; ld < 2*N_F; ld = ld + 1) begin
            @(negedge clk);
            rand_params(pb, pm, ph);
            q_we = 1; q_bank = ld / N_F; q_filt = ld % N_F; q_bias = pb; q_mult = pm; q_shift = ph;
        end
        @(negedge clk) q_we = 0;

        in_bank = 0; since_switch = 1000; rw_active = 0; fresh = 1;
        for (cyc = 0; cyc < N_CYCLES; cyc = cyc + 1) begin
            @(negedge clk);
            if ($random % 4 == 0) in_valid = 0;
            else begin
                in_valid = 1;
                for (flt = 0; flt < N_F; flt = flt + 1) sums[flt*SUM_W +: SUM_W] = rand_sum(0);
            end

            // rewrite the idle bank, one filter per clock
            q_we = 0;
            if (rw_active || (!fresh && since_switch >= 1)) begin
                if (!rw_active) begin rw_active = 1; rw_f = 0; end
                rand_params(pb, pm, ph);
                q_we = 1; q_bank = ~in_bank; q_filt = rw_f; q_bias = pb; q_mult = pm; q_shift = ph;
                rw_f = rw_f + 1;
                if (rw_f == N_F) begin rw_active = 0; fresh = 1; rewrites = rewrites + 1; end
            end

            since_switch = since_switch + 1;
            if (!rw_active && !q_we && fresh && since_switch > 2 && ($random & 7) == 0) begin
                in_bank = ~in_bank; since_switch = 0; fresh = 0; switches = switches + 1;
            end
        end
        @(negedge clk) begin in_valid = 0; q_we = 0; end
        repeat (LAT + 5) @(posedge clk);

        if (errors == 0 && checked > 0)
            $display("PASS: %0d x %0d outputs matched the reference (%0d bank switches, %0d live rewrites; outputs 0: %0d, 1-254: %0d, 255: %0d)",
                     checked, N_F, switches, rewrites, n_zero, n_mid, n_sat);
        else
            $display("FAIL: %0d errors in %0d checks", errors, checked);
        $finish;
    end
endmodule
