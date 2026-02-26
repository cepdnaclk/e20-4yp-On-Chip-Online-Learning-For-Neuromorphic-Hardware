// Filename: stdp_cim_tile.v
// Description: The "Tile" that connects Memory to Logic.

module stdp_cim_tile #(
    parameter NUM_NEURONS = 4,
    parameter WEIGHT_WIDTH = 16,
    parameter ADDR_WIDTH = 10
)(
    input wire clk,
    input wire reset_n,

    // Interface to Network
    input wire [ADDR_WIDTH-1:0] input_addr,
    input wire input_valid,
    input wire [NUM_NEURONS-1:0] neuron_fire_vector,
    input wire [(NUM_NEURONS * WEIGHT_WIDTH)-1:0] neuron_post_traces_flat
);

    // --- Internal Signals ---
    localparam MEM_WIDTH = NUM_NEURONS * WEIGHT_WIDTH;
    
    // Memory Signals
    wire [MEM_WIDTH-1:0] weight_row_in;
    reg  [MEM_WIDTH-1:0] weight_row_out;
    reg  weight_we;
    
    wire [WEIGHT_WIDTH-1:0] pre_trace_out;
    reg  [WEIGHT_WIDTH-1:0] pre_trace_next;
    reg  pre_trace_we;

    // Pipeline Registers
    reg processing_spike;
    reg [NUM_NEURONS-1:0] latch_fire_vec;

    // --- 1. INSTANTIATE MEMORIES (From File 1) ---
    sram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(WEIGHT_WIDTH))
        pre_trace_mem (
            .clk(clk), .write_en(pre_trace_we), .addr(input_addr),
            .data_in(pre_trace_next), .data_out(pre_trace_out)
        );

    sram_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(MEM_WIDTH))
        weight_mem (
            .clk(clk), .write_en(weight_we), .addr(input_addr),
            .data_in(weight_row_out), .data_out(weight_row_in)
        );

    // --- 2. INSTANTIATE LOGIC (From File 2) ---
    // We generate N instances of the logic block, one for each neuron column.
    genvar i;
    generate
        for (i = 0; i < NUM_NEURONS; i = i + 1) begin : gen_stdp_logic
            wire [WEIGHT_WIDTH-1:0] w_in;
            wire [WEIGHT_WIDTH-1:0] w_out;
            wire [WEIGHT_WIDTH-1:0] p_trace;

            // Unpack connections
            assign w_in = weight_row_in[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];
            assign p_trace = neuron_post_traces_flat[i*WEIGHT_WIDTH +: WEIGHT_WIDTH];

            // The Logic Instance
            stdp_update_logic #(
                .WEIGHT_WIDTH(WEIGHT_WIDTH)
            ) core_logic (
                .weight_in(w_in),
                .pre_trace(pre_trace_out),
                .post_trace(p_trace),
                .pre_spike_valid(processing_spike), // Only update if we are processing
                .post_fire(latch_fire_vec[i]),
                .weight_out(w_out)
            );

            // Pack output back to register for writing
            always @(*) begin
                weight_row_out[i*WEIGHT_WIDTH +: WEIGHT_WIDTH] = w_out;
            end
        end
    endgenerate

    // --- 3. CONTROL STATE MACHINE ---
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            processing_spike <= 0;
            pre_trace_we <= 0;
            weight_we <= 0;
        end else begin
            // Reset Write Enables
            pre_trace_we <= 0;
            weight_we <= 0;

            // Step 1: Input Event -> Start Read
            if (input_valid) begin
                processing_spike <= 1;
                latch_fire_vec <= neuron_fire_vector;
            end 
            
            // Step 2: Read Complete -> Compute & Write Back
            else if (processing_spike) begin
                processing_spike <= 0;
                pre_trace_we <= 1;
                weight_we <= 1;
                
                // Logic for Pre-Trace Update (Simple reset on spike)
                pre_trace_next <= {1'b0, {(WEIGHT_WIDTH-1){1'b1}}}; // max trace value on spike
            end
        end
    end

endmodule
