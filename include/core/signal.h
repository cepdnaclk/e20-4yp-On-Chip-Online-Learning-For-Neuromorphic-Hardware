#ifndef NOMAD_CORE_SIGNAL_H
#define NOMAD_CORE_SIGNAL_H

#include <functional>
#include <vector>
#include <string>
#include <iostream>

namespace nomad {

// Forward declaration — Module registers itself as a listener.
class Module;

/// @brief Event-driven wire abstraction, mimicking a Verilog `wire` or `reg`.
///
/// When write() is called with a new value, all registered listener
/// callbacks are invoked (simulating sensitivity in `always @(signal)`).
///
/// @tparam T  The data type carried by this signal (e.g., bool, FixedPoint, SpikePacket).
///
template <typename T>
class Signal {
public:
    /// Construct a signal with a name (for debug / waveform dumping).
    explicit Signal(const std::string& name = "unnamed")
        : name_(name), value_{}, prev_value_{} {}

    // ── Read ──────────────────────────────────────────────────

    /// Read the current value of the signal (non-blocking).
    const T& read() const { return value_; }

    /// Implicit conversion for convenience.
    operator const T&() const { return value_; }

    /// Read the previous value (useful for edge detection).
    const T& prev() const { return prev_value_; }

    // ── Write ─────────────────────────────────────────────────

    /// Write a new value to the signal.
    /// If the value has changed, all registered listeners are notified.
    void write(const T& new_value) {
        if (value_ == new_value) return;  // no event if unchanged

        prev_value_ = value_;
        value_ = new_value;

        // Notify all listeners (event-driven propagation).
        for (auto& callback : listeners_) {
            callback();
        }
    }

    /// Assignment operator — shorthand for write().
    Signal& operator=(const T& new_value) {
        write(new_value);
        return *this;
    }

    // ── Force (for testbenches) ───────────────────────────────

    /// Force a value without triggering events.
    /// Useful for initialisation and test setup.
    void force(const T& val) {
        prev_value_ = value_;
        value_ = val;
    }

    // ── Edge detection helpers ────────────────────────────────

    /// True if the signal just transitioned from false/0 to true/non-zero.
    /// Only meaningful for bool or integer-like types.
    bool posedge() const {
        return static_cast<bool>(value_) && !static_cast<bool>(prev_value_);
    }

    /// True if the signal just transitioned from true/non-zero to false/0.
    bool negedge() const {
        return !static_cast<bool>(value_) && static_cast<bool>(prev_value_);
    }

    // ── Sensitivity registration ──────────────────────────────

    /// Register a callback to be invoked when this signal changes.
    /// Typically called from Module::sensitive_to().
    void add_listener(std::function<void()> callback) {
        listeners_.push_back(callback);
    }

    /// Number of registered listeners.
    size_t listener_count() const { return listeners_.size(); }

    // ── Debug ─────────────────────────────────────────────────

    const std::string& name() const { return name_; }

    friend std::ostream& operator<<(std::ostream& os, const Signal& sig) {
        os << "Signal(" << sig.name_ << " = " << sig.value_ << ")";
        return os;
    }

private:
    std::string name_;
    T value_;
    T prev_value_;
    std::vector<std::function<void()>> listeners_;
};

/// @brief Specialisation helper: a simple clock signal (bool).
using ClockSignal = Signal<bool>;

}  // namespace nomad

#endif  // NOMAD_CORE_SIGNAL_H
