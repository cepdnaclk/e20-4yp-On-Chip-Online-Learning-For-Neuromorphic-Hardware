import numpy as np

# ==========================
# Configurable Parameters
# ==========================

BIT_WIDTH = 8          # change bit width (8, 16, etc.)
DECAY_SHIFT = 3        # decay amount (right shift)

# ==========================
# Derived values
# ==========================

MAX_VAL = (1 << BIT_WIDTH) - 1

start_values = []
next_values = []

# ==========================
# Calculate next value
# ==========================

for value in range(MAX_VAL + 1):

    start_values.append(value)

    decay = value >> DECAY_SHIFT

    if decay != 0:
        next_val = value - decay
    else:
        next_val = 0

    next_values.append(next_val)

    print(f"start: {value:>5}  -> next: {next_val}")

# ==========================
# Non-zero counts (same logic)
# ==========================

print(f"\nstart_values non-zero count: {np.count_nonzero(start_values)}")
print(f"next_values non-zero count: {np.count_nonzero(next_values)}")

print(f"\nstart_values: {start_values}")
print(f"next_values: {next_values}")
