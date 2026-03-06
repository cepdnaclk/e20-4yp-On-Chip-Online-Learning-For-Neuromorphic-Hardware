// Filename: stdp_cim_tile.v
// Description: The "Tile" that connects Memory to Logic.

module stdp_cim_tile #(
    parameter NUMBER_OF_NEURONS = 4,
    parameter WEIGHT_WIDTH = 16,
    parameter ADDRESS_WIDTH = 10
)(
    input wire clock,
    input wire reset_active_low,

    // Interface to Network
    input wire [ADDRESS_WIDTH-1:0] input_address,         
    input wire input_is_valid,                            
    input wire [NUMBER_OF_NEURONS-1:0] neuron_fire_vector,
    input wire [(NUMBER_OF_NEURONS * WEIGHT_WIDTH)-1:0] flat_neuron_post_synaptic_traces
);

    // --- Internal Signals ---
    localparam MEMORY_WIDTH = NUMBER_OF_NEURONS * WEIGHT_WIDTH;
    
    // Memory Signals
    wire [MEMORY_WIDTH-1:0] memory_weight_row_read_data;  
    reg  [MEMORY_WIDTH-1:0] memory_weight_row_write_data; 
    reg  weight_memory_write_enable;                      
    
    wire [WEIGHT_WIDTH-1:0] memory_pre_synaptic_trace_read_data;  
    reg  [WEIGHT_WIDTH-1:0] memory_pre_synaptic_trace_write_data; 
    reg  pre_synaptic_trace_write_enable;                         

    // Pipeline Registers
    reg [ADDRESS_WIDTH-1:0] latched_input_address;             // FIXED: Added to hold address during multi-cycle operations
    reg [NUMBER_OF_NEURONS-1:0] latched_neuron_fire_vector;
    reg is_processing_spike;

    // State Machine States
    localparam STATE_IDLE = 2'b00;         // FIXED: Added formal states for clarity
    localparam STATE_READ_MEMORY = 2'b01;
    localparam STATE_WRITE_MEMORY = 2'b10;
    reg [1:0] current_state;

    // --- 1. INSTANTIATE MEMORIES ---
    // FIXED: Using dual-port implementation with distinct read/write address inputs
    sram_model #(.ADDRESS_WIDTH(ADDRESS_WIDTH), .DATA_WIDTH(WEIGHT_WIDTH))
        pre_synaptic_trace_memory (
            .clock(clock), 
            .write_enable(pre_synaptic_trace_write_enable), 
            .read_address(input_address),             // Continuous read from incoming address
            .write_address(latched_input_address),    // FIXED: Write back uses latched address safely
            .write_data(memory_pre_synaptic_trace_write_data), 
            .read_data(memory_pre_synaptic_trace_read_data)
        );

    sram_model #(.ADDRESS_WIDTH(ADDRESS_WIDTH), .DATA_WIDTH(MEMORY_WIDTH))
        weight_memory (
            .clock(clock), 
            .write_enable(weight_memory_write_enable), 
            .read_address(input_address),             // Continuous read from incoming address
            .write_address(latched_input_address),    // FIXED: Write back uses latched address safely
            .write_data(memory_weight_row_write_data), 
            .read_data(memory_weight_row_read_data)
        );

    // --- 2. INSTANTIATE LOGIC ---
    genvar neuron_index; // Renamed from i
    generate
        for (neuron_index = 0; neuron_index < NUMBER_OF_NEURONS; neuron_index = neuron_index + 1) begin : generate_stdp_logic
            wire [WEIGHT_WIDTH-1:0] individual_weight_input;
            wire [WEIGHT_WIDTH-1:0] individual_weight_output;
            wire [WEIGHT_WIDTH-1:0] individual_post_synaptic_trace;

            // Unpack connections
            assign individual_weight_input = memory_weight_row_read_data[neuron_index*WEIGHT_WIDTH +: WEIGHT_WIDTH];
            assign individual_post_synaptic_trace = flat_neuron_post_synaptic_traces[neuron_index*WEIGHT_WIDTH +: WEIGHT_WIDTH];

            // The Logic Instance
            stdp_update_logic #(
                .WEIGHT_WIDTH(WEIGHT_WIDTH)
            ) core_logic_instance (
                .input_weight(individual_weight_input),
                .pre_synaptic_trace(memory_pre_synaptic_trace_read_data),
                .post_synaptic_trace(individual_post_synaptic_trace),
                .pre_synaptic_spike_is_valid(is_processing_spike),
                .post_synaptic_neuron_fire(latched_neuron_fire_vector[neuron_index]),
                .output_weight(individual_weight_output)
            );

            // Pack output back to register for writing
            always @(*) begin
                memory_weight_row_write_data[neuron_index*WEIGHT_WIDTH +: WEIGHT_WIDTH] = individual_weight_output;
            end
        end
    endgenerate

    // --- 3. CONTROL STATE MACHINE ---
    always @(posedge clock or negedge reset_active_low) begin
        if(!reset_active_low) begin
            is_processing_spike <= 0;
            pre_synaptic_trace_write_enable <= 0;
            weight_memory_write_enable <= 0;
            current_state <= STATE_IDLE;
            latched_input_address <= 0;
            latched_neuron_fire_vector <= 0;
        end else begin
            // Default write enables to off to prevent accidental writes
            pre_synaptic_trace_write_enable <= 0;
            weight_memory_write_enable <= 0;

            case (current_state)
                STATE_IDLE: begin
                    if (input_is_valid) begin
                        latched_input_address <= input_address;           // FIXED: Address safely captured
                        latched_neuron_fire_vector <= neuron_fire_vector; // Captured fire vector
                        current_state <= STATE_READ_MEMORY;
                    end 
                end

                STATE_READ_MEMORY: begin
                    // One clock cycle delay to allow SRAM to output read data
                    is_processing_spike <= 1; // Signal logic block to calculate new weights
                    current_state <= STATE_WRITE_MEMORY;
                end

                STATE_WRITE_MEMORY: begin
                    is_processing_spike <= 0;
                    pre_synaptic_trace_write_enable <= 1; // Trigger write
                    weight_memory_write_enable <= 1;      // Trigger write
                    
                    // Logic for Pre-Trace Update (Simple reset to max on spike)
                    memory_pre_synaptic_trace_write_data <= {1'b0, {(WEIGHT_WIDTH-1){1'b1}}}; 
                    
                    current_state <= STATE_IDLE; // Return to idle
                end
            endcase
        end
    end

endmodule
