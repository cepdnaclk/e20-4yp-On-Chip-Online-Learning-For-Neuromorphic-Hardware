import numpy as np
import matplotlib.pyplot as plt

# ==========================
# Configurable Parameters
# ==========================

BIT_WIDTH = 8
DECAY_SHIFT = 3
MAX_STEPS = 100   # safety limit to stop infinite loops

# ==========================
# Derived values
# ==========================

MAX_VAL = (1 << BIT_WIDTH) - 1

all_histories = []
nonzero_counts = []

# ==========================
# Simulate each start value
# ==========================

for start in range(MAX_VAL + 1):

    value = start
    history = []

    for t in range(MAX_STEPS):

        history.append(value)

        decay = value >> DECAY_SHIFT

        if decay != 0:
            value = value - decay
        else:
            value = 0

        if value == 0:
            history.append(0)
            break

    all_histories.append(history)
    nonzero_counts.append(np.count_nonzero(history))

# ==========================
# Print counts
# ==========================

print(f"Total starting values: {len(all_histories)}")
print(f"Average non-zero length: {np.mean(nonzero_counts)}")
print(f"Max non-zero length: {np.max(nonzero_counts)}")

# ==========================
# Plot curves
# ==========================

for history in all_histories:
    plt.plot(history)

plt.xlabel("Time step")
plt.ylabel("Value")
plt.title(f"Subtractive Integer Decay ({BIT_WIDTH}-bit, shift={DECAY_SHIFT})")
plt.grid()

plt.show()
