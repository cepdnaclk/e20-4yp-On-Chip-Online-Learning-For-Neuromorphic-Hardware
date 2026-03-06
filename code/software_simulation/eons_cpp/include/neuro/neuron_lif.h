#ifndef NOMAD_NEURO_NEURON_LIF_H
#define NOMAD_NEURO_NEURON_LIF_H

#include "core/module.h"
#include "core/signal.h"
#include "core/fixed_point.h"
#include "neuro/spike_packet.h"
#include "neuro/synapse.h"
#include <vector>

namespace nomad {

/// @brief Leaky Integrate-and-Fire (LIF) Neuron — hardware module.
///
/// Models a spiking neuron with:
///   - Membrane potential accumulation (integrate)
///   - Exponential/linear leak each clock cycle
///   - Threshold comparison → spike generation
///   - Refractory period (dead time after firing)
///
/// Verilog-equivalent behaviour:
/// @code
///   always @(posedge clk) begin
///       if (refractory_counter > 0)
///           refractory_counter <= refractory_counter - 1;
///       else begin
///           membrane <= membrane - leak + weighted_input;
///           if (membrane >= threshold) begin
///               spike_out <= 1;
///               membrane <= reset_potential;
///               refractory_counter <= refractory_period;
///           end
///       end
///   end
/// @endcode
///
class NeuronLIF : public Module {
public:
    // ── Ports ─────────────────────────────────────────────────
    Signal<bool>        clk{"neuron_clk"};
    Signal<SpikePacket> spike_in{"spike_in"};   ///< Incoming spike from NOC/synapse.
    Signal<SpikePacket> spike_out{"spike_out"};  ///< Outgoing spike when neuron fires.
    Signal<bool>        fired{"fired"};          ///< High for one cycle when neuron fires.

    // ── Parameters (configurable, stored in memory cluster) ───
    struct Params {
        fp16_8   threshold;          ///< Firing threshold.
        fp16_8   reset_potential;    ///< Membrane resets to this after firing.
        fp16_8   leak_rate;          ///< Amount leaked per clock cycle.
        uint8_t  refractory_period;  ///< Dead cycles after firing.
        uint8_t  neuron_id;          ///< This neuron's ID within its tile.
        uint8_t  tile_x;             ///< This neuron's tile X coordinate.
        uint8_t  tile_y;             ///< This neuron's tile Y coordinate.

        Params()
            : threshold(fp16_8::from_float(1.0f)),
              reset_potential(fp16_8::from_float(0.0f)),
              leak_rate(fp16_8::from_float(0.1f)),
              refractory_period(2),
              neuron_id(0), tile_x(0), tile_y(0) {}
    };

    /// @param name   Module instance name.
    /// @param params Neuron parameters.
    NeuronLIF(const std::string& name, const Params& params = Params())
        : Module(name), params_(params),
          membrane_(fp16_8::zero()),
          refractory_counter_(0),
          spike_count_(0)
    {
        sensitive_to(clk);
        sensitive_to(spike_in);
    }

    void process() override {
        // ── Handle incoming spike (combinational) ─────────
        if (spike_in.read().valid) {
            // Accumulate weighted input into membrane potential.
            pending_input_ += spike_in.read().weight;
        }

        // ── Clock-driven sequential logic ─────────────────
        if (clk.posedge()) {
            clock_tick();
        }
    }

    void initialize() override {
        membrane_ = fp16_8::zero();
        pending_input_ = fp16_8::zero();
        refractory_counter_ = 0;
        spike_count_ = 0;
        fired.force(false);
        spike_out.force(SpikePacket());
    }

    // ── Accessors ─────────────────────────────────────────

    fp16_8 membrane() const { return membrane_; }
    uint32_t spike_count() const { return spike_count_; }
    bool is_refractory() const { return refractory_counter_ > 0; }
    const Params& params() const { return params_; }
    Params& params() { return params_; }

    /// Set the outgoing synapse list (connections this neuron drives).
    void set_synapses(const std::vector<Synapse>& synapses) {
        synapses_ = synapses;
    }

    /// Directly inject current (for testing or external input).
    void inject_current(fp16_8 current) {
        pending_input_ += current;
    }

private:
    Params params_;
    fp16_8 membrane_;
    fp16_8 pending_input_;
    uint8_t refractory_counter_;
    uint32_t spike_count_;
    std::vector<Synapse> synapses_;

    /// One clock tick of the LIF neuron.
    void clock_tick() {
        if (refractory_counter_ > 0) {
            // In refractory period — decrement counter, no integration.
            refractory_counter_--;
            fired.write(false);
            spike_out.write(SpikePacket());  // invalid packet
            pending_input_ = fp16_8::zero();
            return;
        }

        // Integrate: membrane += input - leak
        membrane_ = membrane_ + pending_input_ - params_.leak_rate;
        pending_input_ = fp16_8::zero();

        // Clamp membrane to zero (no negative potential in basic LIF)
        if (membrane_ < fp16_8::zero()) {
            membrane_ = fp16_8::zero();
        }

        // Threshold check
        if (membrane_ >= params_.threshold) {
            // FIRE!
            spike_count_++;
            fired.write(true);

            // Generate spike packets for all outgoing synapses.
            // In a real system, these would be serialised through the NOC.
            // Here we output the first synapse's packet; the NOC Mesh
            // handles fan-out via the synapse table.
            if (!synapses_.empty()) {
                const auto& syn = synapses_[0];
                spike_out.write(SpikePacket(
                    params_.tile_x, params_.tile_y,
                    syn.dst_x, syn.dst_y,
                    syn.dst_neuron, syn.weight
                ));
            } else {
                // No synapses — emit a self-addressed packet as flag.
                spike_out.write(SpikePacket(
                    params_.tile_x, params_.tile_y,
                    params_.tile_x, params_.tile_y,
                    params_.neuron_id, fp16_8::zero()
                ));
            }

            // Reset membrane
            membrane_ = params_.reset_potential;
            refractory_counter_ = params_.refractory_period;
        } else {
            fired.write(false);
            spike_out.write(SpikePacket());  // invalid — no spike
        }
    }
};

}  // namespace nomad

#endif  // NOMAD_NEURO_NEURON_LIF_H
