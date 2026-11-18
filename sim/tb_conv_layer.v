// Unit testbench for the Stage 3b conv_layer (4 filters, two weight banks).
// Self-checking, no data files needed.
//
// What it does, all while windows keep streaming (~75% of clocks carry one):
//   - loads both weight banks through the write port;
//   - switches the bank the incoming windows use, with NO idle clocks
//     around the switch;
//   - GUARD clocks after a switch, rewrites the bank that was just
//     switched away from with new random weights (one weight per clock),
//     while the other bank keeps being used;
//   - repeats ~150 times, and checks all 4 filter outputs of every window
//     against a reference computed when the window goes in.
`timescale 1ns/1ps
module tb_conv_layer;
    localparam N_F   = 4;
    localparam N_W   = N_F * 9;         // weights per bank
    localparam SUM_W = 20;
    localparam LAT   = 11;
    localparam GUARD = 12;              // clocks to wait before rewriting a bank. 6 is the minimum
                                        // (first write lands 8 clocks after the last old window); 5 fails
    localparam N_CYCLES = 10000;

    reg                     clk = 0, rst = 1;
    reg                     in_valid = 0, bank = 0;
    reg  [71:0]             win = 0;
    reg                     w_we = 0, w_bank = 0;
    reg  [5:0]              w_addr = 0;
    reg  [7:0]              w_data = 0;
    wire                    out_valid;
    wire [N_F*SUM_W-1:0]    sums;

    conv_layer #(.N_F(N_F), .SUM_W(SUM_W)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .win(win), .bank(bank),
        .w_we(w_we), .w_bank(w_bank), .w_addr(w_addr), .w_data(w_data),
        .out_valid(out_valid), .sums(sums));

    always #5 clk = ~clk;

    // ---------------- reference model ----------------
    reg [7:0] refA [0:N_W-1];
    reg [7:0] refB [0:N_W-1];

    function signed [31:0] ref_sum(input [71:0] w, input b, input integer flt);
        integer t;
        reg [7:0] k;
        begin
            ref_sum = 0;
            for (t = 0; t < 9; t = t + 1) begin
                k = b ? refB[flt*9 + t] : refA[flt*9 + t];
                ref_sum = ref_sum + $signed({1'b0, w[8*t +: 8]}) * $signed(k);
            end
        end
    endfunction

    reg              v_sr [0:LAT-1];
    reg [4*32-1:0]   e_sr [0:LAT-1];        // expected sums, 32 bits per filter
    reg [4*32-1:0]   e_now;
    integer j, flt, checked = 0, errors = 0;

    initial for (j = 0; j < LAT; j = j + 1) begin v_sr[j] = 0; e_sr[j] = 0; end

    always @(posedge clk) begin
        // compare what leaves the DUT now with what went in LAT clocks ago
        if (!rst && v_sr[LAT-1] !== out_valid) begin     // (out_valid is x until reset clears it)
            errors = errors + 1;
            if (errors <= 10) $display("FAIL: out_valid=%b, expected %b", out_valid, v_sr[LAT-1]);
        end
        if (v_sr[LAT-1]) begin
            for (flt = 0; flt < N_F; flt = flt + 1)
                if (sums[flt*SUM_W +: SUM_W] !== e_sr[LAT-1][flt*32 +: SUM_W]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("FAIL window #%0d filter %0d: sum=%0d expected=%0d",
                                 checked, flt, $signed(sums[flt*SUM_W +: SUM_W]),
                                 $signed(e_sr[LAT-1][flt*32 +: 32]));
                end
            checked = checked + 1;
        end
        // reference for the window going in now (before this edge's weight write lands)
        for (flt = 0; flt < N_F; flt = flt + 1)
            e_now[flt*32 +: 32] = ref_sum(win, bank, flt);
        for (j = LAT-1; j > 0; j = j - 1) begin
            v_sr[j] <= v_sr[j-1];
            e_sr[j] <= e_sr[j-1];
        end
        v_sr[0] <= in_valid & ~rst;
        e_sr[0] <= e_now;
        // mirror the weight write
        if (w_we) begin
            if (w_bank) refB[w_addr] = w_data;
            else        refA[w_addr] = w_data;
        end
    end

    // ---------------- stimulus ----------------
    function [71:0] rand_window(input dummy);
        integer t, r;
        begin
            r = $random & 15;
            for (t = 0; t < 9; t = t + 1)
                rand_window[8*t +: 8] = (r == 0) ? 8'hFF : (r == 1) ? 8'h00 : $random;
        end
    endfunction

    // weight style for a whole bank rewrite: random, all -128, all +127, or small
    integer style;
    function [7:0] rand_weight(input integer st);
        begin
            case (st)
                0:       rand_weight = 8'h80;
                1:       rand_weight = 8'h7F;
                2:       rand_weight = ($random % 3);   // -2..2, like Sobel
                default: rand_weight = $random;
            endcase
        end
    endfunction

    integer ld, cyc, since_switch, rw_idx, switches = 0, rewrites = 0;
    reg     rw_active, fresh;   // rewrite in progress / idle bank rewritten since last switch

    initial begin
        // reset, then load both banks while idle
        repeat (3) @(posedge clk);
        @(negedge clk) rst = 0;
        for (ld = 0; ld < 2*N_W; ld = ld + 1) begin     // own loop variable: j belongs to the checker
            @(negedge clk);
            w_we = 1; w_bank = (ld >= N_W); w_addr = ld % N_W; w_data = $random;
        end
        @(negedge clk) w_we = 0;

        bank = 0; since_switch = 1000; rw_active = 0; fresh = 1;
        for (cyc = 0; cyc < N_CYCLES; cyc = cyc + 1) begin
            @(negedge clk);
            // window (75% of clocks)
            if ($random % 4 == 0) in_valid = 0;
            else begin in_valid = 1; win = rand_window(0); end

            // weight write: continue a rewrite of the idle bank
            w_we = 0;
            // Addresses are written in DESCENDING order: tap 8 of the last filter
            // first. Tap 8 is the last tap to read the old bank, so this is the
            // worst case for the "wait before rewriting" rule.
            if (rw_active) begin
                w_we = 1; w_bank = ~bank; w_addr = N_W-1 - rw_idx; w_data = rand_weight(style);
                rw_idx = rw_idx + 1;
                if (rw_idx == N_W) begin rw_active = 0; fresh = 1; rewrites = rewrites + 1; end
            end else if (!fresh && since_switch >= GUARD) begin
                rw_active = 1; rw_idx = 0; style = $random & 7;
                w_we = 1; w_bank = ~bank; w_addr = N_W-1; w_data = rand_weight(style);
                rw_idx = 1;
            end

            // bank switch: only when the idle bank has fresh weights and isn't being written
            since_switch = since_switch + 1;
            if (!rw_active && !w_we && fresh && since_switch > 2 && ($random & 15) == 0) begin
                bank = ~bank; since_switch = 0; fresh = 0; switches = switches + 1;
            end
        end
        @(negedge clk) begin in_valid = 0; w_we = 0; end
        repeat (LAT + 5) @(posedge clk);

        if (errors == 0 && checked > 0)
            $display("PASS: %0d windows x %0d filters matched the reference (%0d bank switches, %0d live bank rewrites)",
                     checked, N_F, switches, rewrites);
        else
            $display("FAIL: %0d errors in %0d windows", errors, checked);
        $finish;
    end
endmodule
