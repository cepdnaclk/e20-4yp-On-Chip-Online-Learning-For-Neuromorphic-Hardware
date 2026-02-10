# Reward-Modulated STDP (R-STDP) Module

Reward-modulated Spike-Timing-Dependent Plasticity for reinforcement learning in neuromorphic systems.

## Overview

R-STDP extends traditional STDP by incorporating a global reward signal that modulates weight updates. This enables the neuromorphic system to learn from trial-and-error interactions with its environment.

## Learning Rule

R-STDP combines STDP traces with a reward signal:

```
Δw = η * R(t) * e(t)
```

Where:
- `η`: Learning rate
- `R(t)`: Reward signal at time t
- `e(t)`: Eligibility trace (STDP trace)

## Features

- Three-factor learning rule (pre-spike, post-spike, reward)
- Eligibility trace mechanism
- Dopamine-like reward signal integration
- Support for both positive and negative rewards

## Applications

- Reinforcement learning tasks
- Robotic control
- Decision-making systems
- Goal-directed behavior learning

## Parameters

- `TAU_ELIGIBILITY`: Eligibility trace time constant
- `REWARD_WINDOW`: Time window for reward integration
- `LEARNING_RATE`: Global learning rate

## Status

This module is planned for future implementation to enable reinforcement learning capabilities.
