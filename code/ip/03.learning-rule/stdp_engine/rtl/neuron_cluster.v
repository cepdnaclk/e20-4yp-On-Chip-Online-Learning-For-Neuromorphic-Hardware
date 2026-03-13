//==============================================================================
// Project: Neuromorphic Processing System - FYP II
// Module:  neuron_cluster
// Description:
//   A cluster of N leaky integrate-and-fire (LIF) neurons connected through a
//   configurable binary connection matrix with synaptic weights.  Spike-Timing-
//   Dependent Plasticity (STDP) is applied online: when a post-synaptic neuron
//   fires, synaptic weights are potentiated (LTP) for pre-synaptic inputs that
//   spiked recently and depressed (LTD) for those that did not.
//
// Parameters
//   N_NEURONS    : number of neurons in the cluster
//   WEIGHT_WIDTH : bit-width of each synaptic weight
//   MEM_WIDTH    : bit-width of the membrane potential register
//   THRESHOLD    : membrane-potential threshold that triggers a spike
//   LEAK         : membrane-potential decay per clock cycle
//   W_MAX        : maximum weight value (saturation ceiling)
//   W_MIN        : minimum weight value (saturation floor)
//   A_PLUS       : STDP long-term potentiation (LTP) increment
//   A_MINUS      : STDP long-term depression (LTD) decrement
//
// Port descriptions
//   clk          : system clock (rising edge active)
//   rst          : asynchronous active-high reset
//   ext_spike_in : one-hot external spike input bus (one bit per neuron)
//   spike_out    : registered output spike bus (one bit per neuron)
//   conn_matrix  : flattened binary connection matrix
//                  conn_matrix[post*N_NEURONS + pre] == 1  => pre->post synapse
//   weight_init  : flattened initial weight array (loaded when weight_load=1)
//                  weight_init[(post*N_NEURONS+pre)*WEIGHT_WIDTH +: WEIGHT_WIDTH]
//   weight_load  : when asserted for one clock cycle all weights are replaced
//                  with the values on weight_init; neuron dynamics are paused
//   weight_out   : current weight array (same flattened layout as weight_init)
//==============================================================================

`timescale 1ns/1ps

module neuron_cluster #(
    parameter N_NEURONS    = 4,
    parameter WEIGHT_WIDTH = 8,
    parameter MEM_WIDTH    = 16,
    parameter THRESHOLD    = 100,
    parameter LEAK         = 1,
    // NOTE: A_PLUS, A_MINUS, W_MAX and W_MIN are sliced to WEIGHT_WIDTH bits in
    //       the assignments below.  Ensure their values fit within WEIGHT_WIDTH
    //       bits (i.e. < 2**WEIGHT_WIDTH); violating this constraint causes
    //       silent truncation.
    parameter W_MAX        = 255,
    parameter W_MIN        = 0,
    parameter A_PLUS       = 5,
    parameter A_MINUS      = 3
)(
    input  wire                                         clk,
    input  wire                                         rst,

    // External spike injection (one bit per neuron)
    input  wire [N_NEURONS-1:0]                         ext_spike_in,

    // Registered output spikes
    output reg  [N_NEURONS-1:0]                         spike_out,

    // Connection matrix: conn_matrix[post*N+pre] == 1 enables synapse pre->post
    input  wire [N_NEURONS*N_NEURONS-1:0]               conn_matrix,

    // Weight loading interface
    input  wire [N_NEURONS*N_NEURONS*WEIGHT_WIDTH-1:0]  weight_init,
    input  wire                                         weight_load,
    output wire [N_NEURONS*N_NEURONS*WEIGHT_WIDTH-1:0]  weight_out
);

    //--------------------------------------------------------------------------
    // Internal state
    //--------------------------------------------------------------------------
    reg [MEM_WIDTH-1:0]    mem_pot    [0:N_NEURONS-1];
    reg [WEIGHT_WIDTH-1:0] weights    [0:N_NEURONS-1][0:N_NEURONS-1];
    reg [7:0]              pre_trace  [0:N_NEURONS-1];   // eligibility trace for pre-synaptic spikes
    reg [7:0]              post_trace [0:N_NEURONS-1];   // eligibility trace for post-synaptic spikes

    //--------------------------------------------------------------------------
    // Flatten weight_out using generate
    //--------------------------------------------------------------------------
    genvar gi, gj;
    generate
        for (gi = 0; gi < N_NEURONS; gi = gi + 1) begin : wout_row
            for (gj = 0; gj < N_NEURONS; gj = gj + 1) begin : wout_col
                assign weight_out[(gi*N_NEURONS+gj)*WEIGHT_WIDTH +: WEIGHT_WIDTH]
                       = weights[gi][gj];
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // Combinational: aggregate input current and compute fire condition
    //--------------------------------------------------------------------------
    integer ci, cj;

    reg [MEM_WIDTH-1:0] input_cur [0:N_NEURONS-1];
    reg [N_NEURONS-1:0] fire_now;

    always @(*) begin
        for (ci = 0; ci < N_NEURONS; ci = ci + 1) begin
            // Sum weighted spikes from connected pre-synaptic neurons
            input_cur[ci] = {MEM_WIDTH{1'b0}};
            for (cj = 0; cj < N_NEURONS; cj = cj + 1) begin
                if (conn_matrix[ci*N_NEURONS + cj] & spike_out[cj])
                    input_cur[ci] = input_cur[ci]
                                  + {{(MEM_WIDTH-WEIGHT_WIDTH){1'b0}}, weights[ci][cj]};
            end
            // External spike contributes a fixed excitatory current
            if (ext_spike_in[ci])
                input_cur[ci] = input_cur[ci] + {{(MEM_WIDTH-4){1'b0}}, 4'd10};

            // Fire if the updated potential would reach threshold
            fire_now[ci] = ((mem_pot[ci] + input_cur[ci]) >= THRESHOLD) ? 1'b1 : 1'b0;
        end
    end

    //--------------------------------------------------------------------------
    // Sequential: membrane update, trace decay, STDP weight update
    //--------------------------------------------------------------------------
    integer i, j;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < N_NEURONS; i = i + 1) begin
                mem_pot[i]    <= {MEM_WIDTH{1'b0}};
                spike_out[i]  <= 1'b0;
                pre_trace[i]  <= 8'h00;
                post_trace[i] <= 8'h00;
                for (j = 0; j < N_NEURONS; j = j + 1)
                    weights[i][j] <= {WEIGHT_WIDTH{1'b0}};
            end

        end else if (weight_load) begin
            // Bulk-load weights; neuron dynamics paused this cycle
            for (i = 0; i < N_NEURONS; i = i + 1) begin
                spike_out[i] <= 1'b0;
                for (j = 0; j < N_NEURONS; j = j + 1)
                    weights[i][j] <=
                        weight_init[(i*N_NEURONS+j)*WEIGHT_WIDTH +: WEIGHT_WIDTH];
            end

        end else begin
            //------------------------------------------------------------------
            // 1. Update pre-synaptic eligibility traces
            //------------------------------------------------------------------
            for (i = 0; i < N_NEURONS; i = i + 1) begin
                if (ext_spike_in[i])
                    pre_trace[i] <= 8'hFF;           // saturate on external spike
                else if (pre_trace[i] > 8'h00)
                    pre_trace[i] <= pre_trace[i] - 8'd1;  // exponential decay
            end

            //------------------------------------------------------------------
            // 2. Update post-synaptic eligibility traces
            //------------------------------------------------------------------
            for (i = 0; i < N_NEURONS; i = i + 1) begin
                if (fire_now[i])
                    post_trace[i] <= 8'hFF;
                else if (post_trace[i] > 8'h00)
                    post_trace[i] <= post_trace[i] - 8'd1;
            end

            //------------------------------------------------------------------
            // 3. Membrane potential update and spike output
            //------------------------------------------------------------------
            for (i = 0; i < N_NEURONS; i = i + 1) begin
                spike_out[i] <= fire_now[i];
                if (fire_now[i]) begin
                    mem_pot[i] <= {MEM_WIDTH{1'b0}};   // reset after spike
                end else begin
                    // Leaky integration: subtract LEAK then add input current
                    if (mem_pot[i] >= LEAK)
                        mem_pot[i] <= mem_pot[i] - LEAK + input_cur[i];
                    else
                        mem_pot[i] <= input_cur[i];
                end
            end

            //------------------------------------------------------------------
            // 4. STDP: update weights on post-synaptic spike
            //    LTP: pre_trace > 0 (pre fired recently)  -> potentiate
            //    LTD: pre_trace = 0 (pre did not fire)    -> depress
            //------------------------------------------------------------------
            for (i = 0; i < N_NEURONS; i = i + 1) begin
                if (fire_now[i]) begin
                    for (j = 0; j < N_NEURONS; j = j + 1) begin
                        if (conn_matrix[i*N_NEURONS + j]) begin
                            if (pre_trace[j] > 8'h00) begin
                                // LTP: potentiate, clamp to W_MAX
                                if (weights[i][j] <= W_MAX - A_PLUS)
                                    weights[i][j] <= weights[i][j] + A_PLUS[WEIGHT_WIDTH-1:0];
                                else
                                    weights[i][j] <= W_MAX[WEIGHT_WIDTH-1:0];
                            end else begin
                                // LTD: depress, clamp to W_MIN
                                if (weights[i][j] >= W_MIN + A_MINUS)
                                    weights[i][j] <= weights[i][j] - A_MINUS[WEIGHT_WIDTH-1:0];
                                else
                                    weights[i][j] <= W_MIN[WEIGHT_WIDTH-1:0];
                            end
                        end
                    end
                end
            end

        end
    end

endmodule
