// dense layer base module
// module takes a set of inputs
// x*y weights and biases must also be provided
// returns a set of outputs 
// to maximize resources we perform or aim to process ten (parameter) outputs at a time 
// includes LeakyReLU function
// all math is performed in Q1.15 format
// --- stages ---
// stage 0: multiply and initialise
// stage 1: mult_res shifting
// stage 2: bias addition
// stage 3: row addition to calculate op before LeakyReLU
// stage 4: clamping 
// stage 5: LeakyReLU

module dense #(
    parameter m = 10, // no of inputs
    parameter n = 100, // no of outputs 
    parameter alpha = 328, // alpha for LeakyReLU
    parameter sets = 10,
    parameter total_number_of_iterations = 10 // 10 iterations would be required to calculate 100 outputs
)(
    input clk, rst,
    input [16*m*n-1 : 0] weightsf,
    input [16*m*n-1 : 0] biasesf,
    input [16*m-1 : 0] x,
    output [16*n-1 : 0] y,
    output reg resting
);
    wire signed [15:0] ip [0 : m - 1];
    // unflatten the inputs into ip 
    genvar a;
    generate
        for(a = 0; a < m; a = a + 1)
        begin
            assign ip[a] = $signed(x[16*(a + 1) - 1 : 16*a]);
        end
    endgenerate

    reg signed [15:0] op [0 : n - 1];
    // flatten calculted op back into y
    genvar b;
    generate
        for(b = 0; b < n; b = b + 1)
        begin
            assign y[16*(b + 1)-1 : 16*b] = $signed(op[b]);
        end
    endgenerate 


    // assuming first m weights and first m biases correspond to first output 
    wire signed [15:0] weights [0 : m*n - 1];
    wire signed [15:0] biases [0 : m*n - 1];
    // unflatten the weights and biases
    genvar c;
    generate 
        for(c = 0; c < m*n; c = c + 1)
        begin
            assign weights[c] = $signed(weightsf[16*(c + 1) - 1 : 16*c]);
            assign biases[c] = $signed(biasesf[16*(c + 1) - 1 : 16*c]);
        end
    endgenerate

    integer i, j; // for unrolling variables

    // --- stage 0 --- weight multiplication
    reg stage0_valid;
    reg signed [31 : 0] mult_res [0 : sets-1][0 : m-1];
    reg [7 : 0] iter_countw;

    always @ (posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for (i = 0; i < sets; i = i + 1)
            begin 
                for(j = 0; j < m; j = j + 1)
                begin
                    mult_res[i][j] <= 32'sd0;
                end
            end
            iter_countw <= 0;
            stage0_valid <= 1'b0;
        end
        else
        begin
            if(iter_countw < total_number_of_iterations)
            begin
                for (i = 0; i < sets; i = i + 1)
                begin 
                    for(j = 0; j < m; j = j + 1)
                    begin
                        mult_res[i][j] <= ip[j] * weights[(iter_countw * sets + i) * m + j];
                    end
                end
                iter_countw <= iter_countw + 1;
                stage0_valid <= 1'b1;
            end
            else
            begin
                stage0_valid <= 1'b0;
            end
        end
    end 

    // --- stage 1 --- mult_res shifting
    reg stage1_valid;
    reg signed [31 : 0] shifted_mult_res [0 : sets-1][0 : m-1];

    always @ (posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for (i = 0; i < sets; i = i + 1)
                begin 
                    for(j = 0; j < m; j = j + 1)
                    begin
                        shifted_mult_res[i][j] <= 32'sd0;
                    end
                end
            stage1_valid <= 1'b0;
        end
        else
        begin
            if(stage0_valid)
            begin
                for (i = 0; i < sets; i = i + 1)
                begin 
                    for(j = 0; j < m; j = j + 1)
                    begin
                        shifted_mult_res[i][j] <= mult_res[i][j] >>> 15;
                    end
                end
                stage1_valid <= 1'b1;
            end
            else
            begin
                stage1_valid <= 1'b0;
            end
        end
    end

    // --- stage 2 --- bias addition
    reg stage2_valid;
    reg [7 : 0] iter_countb; // two different iter_counts are required to ensure there is no misalignment
    reg signed [31 : 0] bias_addition [0 : sets-1][0 : m-1];

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for (i = 0; i < sets; i = i + 1)
                begin 
                    for(j = 0; j < m; j = j + 1)
                    begin
                        bias_addition[i][j] <= 32'sd0;
                    end
                end
            iter_countb <= 0;
            stage2_valid <= 1'b0;
        end
        else
        begin
            if(stage1_valid)
            begin
                for (i = 0; i < sets; i = i + 1)
                begin 
                    for(j = 0; j < m; j = j + 1)
                    begin
                        bias_addition[i][j] <= shifted_mult_res[i][j] + biases[(iter_countb * sets + i) * m + j];
                    end
                end
                iter_countb <= iter_countb + 1;
                stage2_valid <= 1'b1;
            end
            else
            begin
                stage2_valid <= 1'b0;
            end
        end
    end

    // --- stage 3 --- pre clamped nodal output 
    // A clock triggered block with full blocking assignments 
    reg stage3_valid;
    reg signed [31 : 0] pre_clamped [0 : sets-1];

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < sets; i = i + 1)
            begin
                pre_clamped[i] = 32'sd0;
            end
            stage3_valid = 1'b0;
        end
        else
        begin
            if(stage2_valid)
            begin
                for(i = 0; i < sets; i = i + 1)
                begin
                    pre_clamped[i] = 32'sd0;
                end
                for(i = 0; i < sets; i = i + 1)
                begin
                    for(j = 0; j < m; j = j + 1)
                    begin
                        pre_clamped[i] = pre_clamped[i] + bias_addition[i][j];
                    end
                end
                stage3_valid = 1'b1;
            end
            else
            begin
                stage3_valid = 1'b0; 
            end
        end
    end

    // --- stage 4 --- clamping 
    reg stage4_valid;
    reg signed [15:0] clamped [0 : sets - 1];
    always @ (posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < sets ; i = i + 1)
            begin
                clamped[i] <= 16'sd0;
            end
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
            begin
                stage4_valid <= 1'b0;
            end
        end
    end

    // --- stage 5 --- LeakyReLU
    reg stage5_valid;
    reg signed [31 : 0] LeakyReLU[0 : sets - 1];

    always @ (posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < sets; i = i + 1)
            begin
                LeakyReLU[i] <= 32'sd0;
            end
            stage5_valid <= 1'b0;
        end
        else
        begin
            if(stage4_valid)
            begin
                for (i = 0; i < sets; i = i + 1)
                begin
                    if(clamped[i] == 16'sd0 || clamped[i] > 16'sd0) LeakyReLU[i] <= clamped[i];
                    else LeakyReLU[i] <= ($signed(alpha) * clamped[i]) >>> 15;
                end
                stage5_valid <= 1'b1; 
            end
            else
            begin
                stage5_valid <= 1'b0;
            end
        end
    end

    // --- stage 6 --- final writeback 
    reg [7 : 0] iter_count;

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            for(i = 0; i < n; i = i+1)
            begin
                op[i] <= 16'sd0;
            end
            iter_count <= 0;
            resting <= 1'b0;
        end
        else
        begin
            if(stage5_valid)
            begin
                if(iter_count < total_number_of_iterations)
                begin
                    for(i = 0; i < sets; i = i + 1)
                    begin
                        op[i + iter_count*sets] <= $signed(LeakyReLU[i][15 : 0]);
                    end
                    iter_count <= iter_count + 1;
                end
            end
            else
            begin
                if(iter_count == total_number_of_iterations)
                begin
                    resting <= 1'b1;
                end
                else 
                begin
                    resting <= 1'b0;
                end
            end
        end
    end
endmodule
