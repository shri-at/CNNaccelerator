// Pipelined ProducePartialFM (ModelSim-friendly)
// Q1.15 fixed point, 3 kernels (fixed layer depth)
// x, y and gen_count register bit widths should be changed according to ip_size and kernel_size requirement
// Pipeline stages: WindowFetch -> Multiply -> Shift -> Accumulate -> Clamp/Writeback

module ProducePartialFM #(
    parameter ip_size  = 6,
    parameter kernel_size = 3,
    parameter op_size = ip_size - kernel_size + 1
)(
    input  clk,
    input  rst, // active high

    // flattened inputs
    input  signed [16*ip_size*ip_size - 1 : 0] ipf,
    input  signed [16*kernel_size*kernel_size - 1 : 0] K1f,
    input  signed [16*kernel_size*kernel_size - 1 : 0] K2f,
    input  signed [16*kernel_size*kernel_size - 1 : 0] K3f,

    // flattened outputs (wires - driven by assigns to per-element regs)
    output reg resting,
    output signed [16*op_size*op_size - 1 : 0] IK1,
    output signed [16*op_size*op_size - 1 : 0] IK2,
    output signed [16*op_size*op_size - 1 : 0] IK3
);

    // Derived constants (evaluate at elaboration)
    localparam integer total_outputs = op_size * op_size;

    // --- Unpack flattened inputs into 2D wires ---
    wire signed [15:0] ip [0:ip_size-1][0:ip_size-1];
    wire signed [15:0] K1 [0:kernel_size-1][0:kernel_size-1];
    wire signed [15:0] K2 [0:kernel_size-1][0:kernel_size-1];
    wire signed [15:0] K3 [0:kernel_size-1][0:kernel_size-1];

    genvar gx, gy;
    generate
        for (gy = 0; gy < ip_size; gy = gy + 1)
            for (gx = 0; gx < ip_size; gx = gx + 1) 
                assign ip[gx][gy] = ipf[16*(gx + gy*ip_size + 1)-1 -: 16];
        for (gy = 0; gy < kernel_size; gy = gy + 1)
            for (gx = 0; gx < kernel_size; gx = gx + 1)
            begin
                assign K1[gx][gy] = K1f[16*(gx + gy*kernel_size + 1)-1 -: 16];
                assign K2[gx][gy] = K2f[16*(gx + gy*kernel_size + 1)-1 -: 16];
                assign K3[gx][gy] = K3f[16*(gx + gy*kernel_size + 1)-1 -: 16];
            end
    endgenerate

    // --- Output storage (per-element) ---
    reg signed [15:0] opIK1 [0:total_outputs-1];
    reg signed [15:0] opIK2 [0:total_outputs-1];
    reg signed [15:0] opIK3 [0:total_outputs-1];

    // flatten outputs by assigning from arrays (IKx are wires)
    genvar gz;
    generate
        for (gz = 0; gz < total_outputs; gz = gz + 1) 
        begin 
            assign IK1[16*(gz+1)-1 -: 16] = opIK1[gz];
            assign IK2[16*(gz+1)-1 -: 16] = opIK2[gz];
            assign IK3[16*(gz+1)-1 -: 16] = opIK3[gz];
        end
    endgenerate

    // --- Pipeline registers & control (module-scope declarations only) ---
    // Stage0: window (kernel_size x kernel_size)
    reg signed [15:0] ip_subset [0:kernel_size-1][0:kernel_size-1];
    reg stage0_valid;
    // x, y index windows (range 0..op_size-1). width chosen small but safe.
    reg [5:0] x; 
    reg [5:0] y;
    reg [7:0] gen_count; // counts windows generated (total_outputs <= 36 for typical sizes)

    // Stage1: multiply results (Q2.30)
    reg signed [31:0] mult1_reg [0:kernel_size-1][0:kernel_size-1];
    reg signed [31:0] mult2_reg [0:kernel_size-1][0:kernel_size-1];
    reg signed [31:0] mult3_reg [0:kernel_size-1][0:kernel_size-1];
    reg stage1_valid;

    // Stage2: shifted results (Q1.15)
    reg signed [15:0] sh1_reg [0:kernel_size-1][0:kernel_size-1];
    reg signed [15:0] sh2_reg [0:kernel_size-1][0:kernel_size-1];
    reg signed [15:0] sh3_reg [0:kernel_size-1][0:kernel_size-1];
    reg stage2_valid;

    // Stage3: sums (20-bit)
    reg signed [19:0] sum1_reg;
    reg signed [19:0] sum2_reg;
    reg signed [19:0] sum3_reg;
    reg stage3_valid;

    // Stage4: writeback / count
    reg [7:0] out_count; 

    // tmp accumulators declared at module scope (no declarations inside always)
    reg signed [19:0] tmp1;
    reg signed [19:0] tmp2;
    reg signed [19:0] tmp3;

    // integer loop indices at module scope
    integer i, j;

    // ----------------------------
    // Stage0: Window generation
    // produce one 3x3 window per cycle while gen_count < total_outputs
    // ----------------------------

    always @(posedge clk or posedge rst)
    begin
        if(rst)
        begin
            x <= 0;
            y <= 0;
            gen_count <= 0;
            stage0_valid <= 1'b0;
            // clear window registers
            for (i = 0; i < kernel_size; i = i + 1)
                for (j = 0; j < kernel_size; j = j + 1)
                    ip_subset[i][j] <= 16'sd0;
        end
        else
        begin
            if(gen_count == 0)
            begin
                for (i = 0; i < kernel_size; i = i + 1)
                    for (j = 0; j < kernel_size; j = j + 1)
                        ip_subset[i][j] <= ip[i][j];
                stage0_valid <= 1'b1;
                gen_count <= gen_count + 1;
            end
            else if (gen_count < total_outputs)
            begin
                for(i = 0; i < kernel_size; i = i + 1)
                    for(j = 0; j < kernel_size - 1; j = j+1)
                        ip_subset[i][j] <= ip_subset[i][j + 1];
                for(i = 0; i < kernel_size; i = i + 1)
                    ip_subset[i][kernel_size - 1] <= ip[i + x][y + kernel_size];
                    
                if(y < op_size-2)
                begin
                    y <= y + 1;
                end
                else
                begin
                    y <= 0;
                    if(x < op_size-1) x <= x + 1;
                    else x <= 0;
                end
                stage0_valid <= 1'b1;
                gen_count <= gen_count + 1;
            end
            else
            begin
                stage0_valid <= 1'b0;
            end
        end
    end

    // ----------------------------
    // Stage1: Multiply (register results)
    // ----------------------------
    always @(posedge clk or posedge rst) 
    begin
        if (rst) 
        begin
            stage1_valid <= 1'b0;
            for (i = 0; i < kernel_size; i = i + 1)
                for (j = 0; j < kernel_size; j = j + 1) 
                begin
                    mult1_reg[i][j] <= 32'sd0;
                    mult2_reg[i][j] <= 32'sd0;
                    mult3_reg[i][j] <= 32'sd0;
                end
        end 
        else 
        begin
            if (stage0_valid) 
            begin
                for (i = 0; i < kernel_size; i = i + 1)
                    for (j = 0; j < kernel_size; j = j + 1) 
                    begin
                        mult1_reg[i][j] <= $signed(ip_subset[i][j]) * $signed(K1[i][j]);
                        mult2_reg[i][j] <= $signed(ip_subset[i][j]) * $signed(K2[i][j]);
                        mult3_reg[i][j] <= $signed(ip_subset[i][j]) * $signed(K3[i][j]);
                    end
                stage1_valid <= 1'b1;
            end 
            else 
            begin
                stage1_valid <= 1'b0;
            end
        end
    end

    // ----------------------------
    // Stage2: Shift down by 15 (Q2.30 -> Q1.15)
    // ----------------------------
    always @(posedge clk or posedge rst) 
    begin
        if (rst) 
        begin
            stage2_valid <= 1'b0;
            for (i = 0; i < kernel_size; i = i + 1)
                for (j = 0; j < kernel_size; j = j + 1) 
                begin
                    sh1_reg[i][j] <= 16'sd0;
                    sh2_reg[i][j] <= 16'sd0;
                    sh3_reg[i][j] <= 16'sd0;
                end
        end 
        else 
        begin
            if (stage1_valid) 
            begin
                for (i = 0; i < kernel_size; i = i + 1)
                    for (j = 0; j < kernel_size; j = j + 1) 
                    begin
                        sh1_reg[i][j] <= mult1_reg[i][j] >>> 15;
                        sh2_reg[i][j] <= mult2_reg[i][j] >>> 15;
                        sh3_reg[i][j] <= mult3_reg[i][j] >>> 15;
                    end
                stage2_valid <= 1'b1;
                // clearing 
                tmp1 = 20'sd0;
                tmp2 = 20'sd0;
                tmp3 = 20'sd0;
            end 
            else 
            begin
                stage2_valid <= 1'b0;
            end
        end
    end

    // ----------------------------
    // Stage3: Accumulate (sum 3x3 shifted products) into 20-bit sums
    // ----------------------------
    always @(posedge clk or posedge rst) 
    begin
        if (rst) 
        begin
            stage3_valid <= 1'b0;
            sum1_reg <= 20'sd0;
            sum2_reg <= 20'sd0;
            sum3_reg <= 20'sd0;
            tmp1 <= 20'sd0;
            tmp2 <= 20'sd0;
            tmp3 <= 20'sd0;
        end 
        else 
        begin
            if (stage2_valid == 1'b0) 
            begin
                stage3_valid <= 1'b0;
            end
        end
    end

    always @ (stage2_valid)
    begin
        if(stage2_valid)
        begin
            // sign-extend each 16-bit product to 20 bits then accumulate
            for (i = 0; i < kernel_size; i = i + 1) 
            begin
                for (j = 0; j < kernel_size; j = j + 1) 
                begin
                    tmp1 = tmp1 + {{4{sh1_reg[i][j][15]}}, sh1_reg[i][j]};
                    tmp2 = tmp2 + {{4{sh2_reg[i][j][15]}}, sh2_reg[i][j]};
                    tmp3 = tmp3 + {{4{sh3_reg[i][j][15]}}, sh3_reg[i][j]};
                end
            end
            sum1_reg = tmp1;
            sum2_reg = tmp2;
            sum3_reg = tmp3;
            stage3_valid = 1'b1;
        end
        else 
        begin
            stage3_valid = 1'b0;
        end
    end

    // ----------------------------
    // Stage4: Clamp, writeback to opIK arrays, increment out_count, set resting when done
    // ----------------------------
    always @(posedge clk or posedge rst) 
    begin
        if (rst) 
        begin
            out_count <= 0;
            resting <= 1'b0;
            for (i = 0; i < total_outputs; i = i + 1) 
            begin
                opIK1[i] <= 16'sd0;
                opIK2[i] <= 16'sd0;
                opIK3[i] <= 16'sd0;
            end
        end 
        else 
        begin
            if (stage3_valid) 
            begin
                // clamp to signed 16-bit Q1.15 range [-32768, +32767]
                if (sum1_reg > 20'sh07FFF) opIK1[out_count] <= 16'sh7FFF;
                else if (sum1_reg < -20'sh08000) opIK1[out_count] <= 16'sh8000;
                else opIK1[out_count] <= sum1_reg[15:0];

                if (sum2_reg > 20'sh07FFF) opIK2[out_count] <= 16'sh7FFF;
                else if (sum2_reg < -20'sh08000) opIK2[out_count] <= 16'sh8000;
                else opIK2[out_count] <= sum2_reg[15:0];

                if (sum3_reg > 20'sh07FFF) opIK3[out_count] <= 16'sh7FFF;
                else if (sum3_reg < -20'sh08000) opIK3[out_count] <= 16'sh8000;
                else opIK3[out_count] <= sum3_reg[15:0];

                // increment out_count after writing
                out_count <= out_count + 1;

                // assert resting on the cycle we wrote the last element
                if (out_count == total_outputs - 1) resting <= 1'b1;
            end 
        end
    end
endmodule
