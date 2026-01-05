// last dense layer module to return the index of the maximum
// module takes a set of inputs
// x*y weights and biases must also be provided
// returns a one-hot output (argmax)
// all math is performed in Q1.15 format
// --- stages ---
// stage 0: multiply and initialise
// stage 1: mult_res shifting
// stage 2: bias addition
// stage 3: row addition to calculate op before clamping
// stage 4: clamping 
// stage 5: argmax (final stage)

module dense #(
    parameter m = 10, // no of inputs
    parameter n = 100, // no of outputs 
    parameter sets = 10,
    parameter total_number_of_iterations = 10 // 10 iterations required for 100 outputs
)(
    input  clk, rst,
    input  [16*m*n-1 : 0] weightsf,
    input  [16*m*n-1 : 0] biasesf,
    input  [16*m-1 : 0]   x,
    output reg [n-1:0]    y,           
    output reg            resting
);

    // --- input unflattening ---
    wire signed [15:0] ip [0 : m - 1];
    genvar a;
    generate
        for(a = 0; a < m; a = a + 1)
            assign ip[a] = $signed(x[16*(a + 1) - 1 : 16*a]);
    endgenerate

    // --- weights and biases unflattening ---
    wire signed [15:0] weights [0 : m*n - 1];
    wire signed [15:0] biases  [0 : m*n - 1];
    genvar b;
    generate 
        for(b = 0; b < m*n; b = b + 1)
        begin
            assign weights[b] = $signed(weightsf[16*(b + 1) - 1 : 16*b]);
            assign biases[b]  = $signed(biasesf [16*(b + 1) - 1 : 16*b]);
        end
    endgenerate

    integer i, j; // loop indices

    // --- stage 0 --- weight multiplication 
    reg stage0_valid;
    reg signed [31 : 0] mult_res [0 : sets-1][0 : m-1];
    reg [7 : 0] iter_countw;

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for (i = 0; i < sets; i = i + 1)
                for(j = 0; j < m; j = j + 1)
                    mult_res[i][j] <= 32'sd0;
            iter_countw  <= 0;
            stage0_valid <= 1'b0;
        end
        else
        begin
            if(iter_countw < total_number_of_iterations)
            begin
                for (i = 0; i < sets; i = i + 1)
                    for(j = 0; j < m; j = j + 1)
                        mult_res[i][j] <= ip[j] * weights[(iter_countw * sets + i) * m + j];
                iter_countw  <= iter_countw + 1;
                stage0_valid <= 1'b1;
            end
            else
                stage0_valid <= 1'b0;
        end
    end 

    // --- stage 1 --- mult_res shifting 
    reg stage1_valid;
    reg signed [31 : 0] shifted_mult_res [0 : sets-1][0 : m-1];

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for (i = 0; i < sets; i = i + 1)
                for(j = 0; j < m; j = j + 1)
                    shifted_mult_res[i][j] <= 32'sd0;
            stage1_valid <= 1'b0;
        end
        else
        begin
            if(stage0_valid)
            begin
                for (i = 0; i < sets; i = i + 1)
                    for(j = 0; j < m; j = j + 1)
                        shifted_mult_res[i][j] <= mult_res[i][j] >>> 15;
                stage1_valid <= 1'b1;
            end
            else
                stage1_valid <= 1'b0;
        end
    end

    // --- stage 2 --- bias addition 
    reg stage2_valid;
    reg [7 : 0] iter_countb;
    reg signed [31 : 0] bias_addition [0 : sets-1][0 : m-1];

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for (i = 0; i < sets; i = i + 1)
                for(j = 0; j < m; j = j + 1)
                    bias_addition[i][j] <= 32'sd0;
            iter_countb  <= 0;
            stage2_valid <= 1'b0;
        end
        else
        begin
            if(stage1_valid)
            begin
                for (i = 0; i < sets; i = i + 1)
                    for(j = 0; j < m; j = j + 1)
                        bias_addition[i][j] <= shifted_mult_res[i][j] + biases[(iter_countb * sets + i) * m + j];
                iter_countb  <= iter_countb + 1;
                stage2_valid <= 1'b1;
            end
            else
                stage2_valid <= 1'b0;
        end
    end

    // --- stage 3 --- pre clamped nodal output 
    reg stage3_valid;
    reg signed [31 : 0] pre_clamped [0 : sets-1];

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < sets; i = i + 1)
                pre_clamped[i] = 32'sd0;
            stage3_valid = 1'b0;
        end
        else
        begin
            if(stage2_valid)
            begin
                for(i = 0; i < sets; i = i + 1)
                    pre_clamped[i] = 32'sd0;

                for(i = 0; i < sets; i = i + 1)
                    for(j = 0; j < m; j = j + 1)
                        pre_clamped[i] = pre_clamped[i] + bias_addition[i][j];

                stage3_valid = 1'b1;
            end
            else
                stage3_valid = 1'b0;
        end
    end

    // --- stage 4 --- clamping 
    reg stage4_valid;
    reg signed [15:0] clamped [0 : sets - 1];

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < sets ; i = i + 1)
                clamped[i] <= 16'sd0;
            stage4_valid <= 1'b0;
        end
        else
        begin
            if(stage3_valid)
            begin
                for(i = 0; i < sets; i = i + 1)
                begin
                    if (pre_clamped[i] > 32'sd32767) clamped[i] <= 16'sh7FFF;
                    else if(pre_clamped[i] < -32'sd32768) clamped[i] <= 16'sh8000;
                    else clamped[i] <= $signed(pre_clamped[i][15 : 0]);
                end
                stage4_valid <= 1'b1;
            end
            else
                stage4_valid <= 1'b0;
        end
    end

    // --- stage 5 --- argmax
    reg [7:0] batch_idx;
    reg signed [15:0] global_max_val;
    reg [7:0] global_max_idx;
    reg signed [15:0] local_max_val;
    reg [7:0] local_max_idx;

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < n; i = i + 1)
                y[i] = 1'b0;                   
            batch_idx      = 0;
            global_max_val = 16'sh8000; // minimum possible
            global_max_idx = 0;
            local_max_val  = 16'sd0;
            local_max_idx  = 8'd0;
            resting        = 1'b0;
        end
        else
        begin
            if(stage4_valid)
            begin
                local_max_val = clamped[0];
                local_max_idx = 8'd0;
                for(i = 1; i < sets; i = i + 1)
                begin
                    if((batch_idx * sets + i) < n)
                    begin
                        if(clamped[i] > local_max_val)
                        begin
                            local_max_val = clamped[i];
                            local_max_idx = i[7:0];
                        end
                    end
                end

                if(local_max_val > global_max_val)
                begin
                    global_max_val = local_max_val;
                    global_max_idx = batch_idx * sets + local_max_idx;
                end

                // increment batch index
                batch_idx = batch_idx + 1;

                // one hot encoding
                if(batch_idx == total_number_of_iterations - 1)
                begin
                    for(i = 0; i < n; i = i + 1)
                        y[i] = 1'b0;
                    if(global_max_idx < n)
                        y[global_max_idx] = 1'b1;   
                    resting = 1'b1;
                end
                else
                    resting = 1'b0;
            end
            else
                resting = 1'b0;
        end
    end
endmodule
