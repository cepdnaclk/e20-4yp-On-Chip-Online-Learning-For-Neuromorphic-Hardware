VCD info: dumpfile tb_neuron_cluster.vcd opened for output.
=============================================================
  tb_neuron_cluster â€” Fixed Integration Testbench
  CLK_PERIOD_NS         : 10 ns
  MAX_SIMULATION_CYCLES : 50000 cycles
  MAX_STDP_WAIT_CYCLES  : 500 cycles per STDP wait
  INCREASE_MODE         : 0 (0=SET_MAX â†’ post trace = 0xFF)
=============================================================
[PASS] T01: Cluster idle after reset
--- Setup: configuring connection matrix ---
--- Setup: loading weights from init_weights.hex ---
--- Setup: pre-loading neuron 1 trace: value=128, timestamp=0, saturated=0 ---
[PASS] T02: Neuron 1 trace: value=128, timestamp=0, saturated=0 confirmed
[PASS] T03: Initial weight W[0][1]=100 stored at Bank 1 Addr 0
--- Test: neuron 0 fires (post-synaptic STDP event) ---
[PASS] T04: cluster_busy_flag high after neuron 0 spike injected
       [TIMEOUT] busy still high after 500 cycles.
       Increase MAX_STDP_WAIT_CYCLES if needed.
[FAIL] T05: STDP cycle 1 completes within cycle budget
       Completed in 500 cycles
[FAIL] T06: LTP: W[0][1] increased from 100 to 132 after neuron 0 fires
       Expected 132, got 100
[PASS] T07: Post-synaptic trace (neuron 0): SET_Mÿÿÿâÿ’ 0xFF, saturated=0
[FAIL] T08: Cluster idle before decay pulses
--- Applying 8 decay enable pulses ---
[FAIL] T09: Cluster remains idle during 8 decay pulses
[PASS] T10: Neuron 0 raw trace still 0xFF (lazy decay: no in-place update)
       Stored timestamp after firing: 0 decay ticks
--- Test: neuron 0 fires again after 8 decay ticks ---
[PASS] T11: cluster_busy_flag high after second neuron 0 spike
       [TIMEOUT] busy still high after 500 cycles.
       Increase MAX_STDP_WAIT_CYCLES if needed.
[FAIL] T12: STDP cycle 2 completes within cycle budget
       Completed in 500 cycles
[FAIL] T13: LTP cycle 2: W[0][1] updated correctly with decayed pre-trace
       Effective pre-trace after 8 ticks: 64 | Expected weight: 148, got: 100
--- Test: neuron 3 fires (no connections configured) ---
       [TIMEOUT] busy still high after 500 cycles.
       Increase MAX_STDP_WAIT_CYCLES if needed.
[FAIL] T14: STDP cycle for neuron 3 (no connections) completes
[FAIL] T15: W[0][1] unchanged after neuron 3 fires (not connected)
--- Test: simultaneous spikes on neurons 1 and 2 ---
[PASS] T16: Cluster busy after simultaneous spikes (T13)
       [TIMEOUT] busy still high after 500 cycles.
       Increase MAX_STDP_WAIT_CYCLES if needed.
[FAIL] T17: Both simultaneous spikes processed within cycle budget (T14)
       Both STDP cycles completed in 500 cycles
[PASS] T18: cluster_spike_output_bus is 0 when no neurons are firing
--- Test: reset applied mid-run ---
[PASS] T19: Cluster idle after mid-run reset
[PASS] T20: uster busy after post-reset spike injection (pipeline restarted)
[PASS] T21: Post-reset STDP cycle completes cleanly

=============================================================
  FINAL RESULTS: 12 passed, 9 failed out of 21 tests
  FAILURES DETECTED â€” review [FAIL] lines above
=============================================================
tb/tb_neuron_cluster.v:668: $finish called at 20656000 (1ps)
