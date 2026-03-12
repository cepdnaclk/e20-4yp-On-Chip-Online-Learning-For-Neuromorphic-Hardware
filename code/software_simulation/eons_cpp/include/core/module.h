#ifndef NOMAD_CORE_MODULE_H
#define NOMAD_CORE_MODULE_H

#include "signal.h"
#include <cstdint>
#include <string>
#include <vector>
#include <functional>

namespace nomad {

/// @brief Base class for all hardware modules.
///
/// Mirrors a Verilog `module`. Each derived class implements process(),
/// which is called whenever a signal in its sensitivity list changes.
///
/// Usage:
/// @code
///   class MyNeuron : public Module {
///   public:
///       Signal<bool> spike_in;
///       Signal<bool> spike_out;
///
///       MyNeuron() : Module("neuron") {
///           sensitive_to(spike_in);
///       }
///
///       void process() override {
///           if (spike_in.read()) {
///               spike_out.write(true);
///           }
///       }
///   };
/// @endcode
///
class Module {
public:
    /// Construct a module with a name (for debug / hierarchy printing).
    explicit Module(const std::string& name = "unnamed_module");

    /// Virtual destructor for polymorphism.
    virtual ~Module() = default;

    // ── Core interface ────────────────────────────────────────

    /// Called by the simulation kernel whenever a sensitive signal changes.
    /// Derived classes implement their combinational or sequential logic here.
    virtual void process() = 0;

    /// Called once at the start of simulation.
    /// Override to set initial signal values, load memory, etc.
    virtual void initialize() {}

    /// Called once at the end of simulation.
    /// Override to dump final state, collect statistics, etc.
    virtual void finalize() {}

    // ── Sensitivity ───────────────────────────────────────────

    /// Register this module's process() to be called when `sig` changes.
    template <typename T>
    void sensitive_to(Signal<T>& sig) {
        sig.add_listener([this]() { this->process(); });
    }

    // ── Identity ──────────────────────────────────────────────

    const std::string& name() const { return name_; }
    void set_name(const std::string& name) { name_ = name; }

    /// Unique module ID (assigned at construction time).
    uint32_t id() const { return id_; }

    // ── Hierarchy (optional, for debug) ───────────────────────

    /// Add a child module (for hierarchical naming / printing).
    void add_child(Module* child);

    /// Get all child modules.
    const std::vector<Module*>& children() const { return children_; }

    /// Print the module hierarchy tree (for debugging).
    void print_hierarchy(int indent = 0) const;

private:
    std::string name_;
    uint32_t id_;
    std::vector<Module*> children_;

    static uint32_t next_id_;  // global counter for unique IDs
};

}  // namespace nomad

#endif  // NOMAD_CORE_MODULE_H
