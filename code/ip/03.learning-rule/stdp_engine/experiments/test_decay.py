import numpy as np
import matplotlib.pyplot as plt

# ==========================
# Configurable Parameters
# ==========================

BIT_WIDTH = 8          # change bit width (8, 16, etc.)
DECAY_SHIFT = 3        # decay amount (right shift)
TIME_STEPS = 50        # simulation length

# ==========================
# Initial value (max value)
# ==========================

MAX_VAL = (1 << BIT_WIDTH) - 1

value_shift = MAX_VAL
value_sub = MAX_VAL

shift_history = []
sub_history = []

# ==========================
# Simulation
# ==========================

for t in range(TIME_STEPS):

    shift_history.append(value_shift)
    sub_history.append(value_sub)

    # Method 1: shift only
    value_shift = value_shift >> DECAY_SHIFT

    # Method 2: subtractive exponential decay
    decay = value_sub >> DECAY_SHIFT
    if(decay!=0):
        value_sub = value_sub - (decay)
    else:
        value_sub = 0

# ==========================
# Plot results
# ==========================

# Using the numpy trick to count non-zero values
print(f"shift_history non-zero count: {np.count_nonzero(shift_history)}")
print(f"sub_history non-zero count: {np.count_nonzero(sub_history)}")

print(f"shift_history: {shift_history}")
print(f"sub_history: {sub_history}")

plt.plot(shift_history, label="new = old >> decay_shift")
plt.plot(sub_history, label="new = old - (old >> decay_shift)")

plt.xlabel("Time step")
plt.ylabel("Value")
plt.title(f"Integer Decay Comparison ({BIT_WIDTH}-bit, shift={DECAY_SHIFT})")
plt.legend()
plt.grid()

plt.show()

