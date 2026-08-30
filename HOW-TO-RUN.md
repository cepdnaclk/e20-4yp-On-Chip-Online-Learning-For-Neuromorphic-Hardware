# How to run this project

A plain-English guide. No hardware knowledge needed. If you can copy a line into
a terminal, you can run every experiment in here.

---

## 1. What this thing actually is

We built a **brain-like chip design that teaches itself to read handwritten
digits**.

The important word is *itself*. Normal AI is trained on a big computer first,
and only then is the finished result loaded onto a chip — the chip never learns
anything, it just answers. Ours is the other way round: the chip is switched on
knowing nothing, is shown handwriting, and **rewires its own connections as it
watches**. Nobody ever tells it "that was a 7". It works out on its own that
certain shapes belong together, and only at the very end do we check which
digit each part of it settled on.

The chip doesn't physically exist yet. It's a full blueprint (written in a
language called Verilog), and we run that blueprint through a **simulator** — a
program that pretends to be the chip, wire by wire. That's why runs take hours:
the simulator is doing on one computer what real silicon would do instantly.

**A note on the numbers below.** The best score is about 42% correct. Against a
polished image-recognition app that sounds low — but the honest comparison is
against *guessing*, which scores 10%. And this thing learned it from only 720
examples, with nobody ever telling it the right answer. See section 8 for a
straight assessment of what that is and isn't worth.

---

## 2. Set up (once)

**Two things needed.**

```bash
sudo pacman -S iverilog          # the simulator
```

*(That's the Arch Linux command — the project is developed on Arch. On Ubuntu
it's `sudo apt install iverilog`.)*

Then get the handwriting images:

```bash
cd code/ip/03.learning-rule/stdp_engine
make download_mnist
```

That downloads MNIST — 70,000 photos of handwritten digits, the standard
practice set everyone uses. It's about 55 MB and only needs doing once. If you
already have the files it just says `[skip]` and exits.

**Everything from here on is run from that same folder**, so stay there:

```
code/ip/03.learning-rule/stdp_engine
```

> **Check it works:** `make test_all` runs seven quick self-checks on the
> individual pieces and takes under a minute. If those pass, the setup is good.

---

## 3. The four experiments

Each is **one command**. Nothing to edit, no files to open.

### The baseline — one cluster

```bash
make mnist
```

One group of 128 slots. 100 of them hold the picture, the other 28 are the
learning neurons. **Scored 29.58%.**

### The best one — wide

```bash
make mnist_wide
```

Four separate groups, each seeing the whole picture and forming its own
opinion, then all 112 neurons vote at the end. **Scored 41.67%.** This is the
one to run if you only run one.

### The one that didn't work — layered

```bash
make mnist_layered
```

Two stages: four groups each study one *quarter* of the picture, then pass a
summary to a fifth group that makes the final call. **Scored 11.25%**, which is
barely better than guessing. Section 6 explains why it failed — it's an
interesting failure, not a broken program.

### Higher resolution — wide at 14×14

```bash
make mnist_wide MNIST_GRID=14 MNIST_CLUSTERS=2 MNIST_NEURONS=256 MNIST_TIMESTEPS=15
```

Same winning idea, but each picture is 14×14 instead of 10×10. **Scored
32.92%** — worse, and section 6 explains that too. This one took **6 hours 11
minutes**, the only run whose time we recorded precisely. The others are
roughly 2–4 hours. Start one and go do something else.

---

## 4. Reading the result

At the end you get:

```
ACCURACY : 41.67 %      100 of 240 test images
Health   : queue overflow=0  stdp timeout=0  router overflow=0
```

**Two things to look at.**

**The accuracy.** Out of 240 pictures it had never seen, how many it got right.
Guessing would give about 10%.

**The health line — this one matters more.** Every number must be **zero**.
Zeros mean the hardware ran cleanly and the score is real. Anything non-zero
means the design jammed, and the score is meaningless — a fault, not a bad
result. Every run so far has been all zeros.

You'll also see little pictures made of `#` and `+` symbols. Those are the
**actual learned connections read back out of the chip's memory** — each one is
what a single neuron has decided to look for. When learning works you can see
digit shapes in them. It's the most direct proof that anything was learned at
all.

Every run is saved automatically under `runs/` with a date-stamped folder
holding the full log, the settings used, and the headline score. Nothing is
ever overwritten, so old results stay comparable. `make clean` doesn't touch
them.

---

## 5. Designing your own version

### The one rule

Picture a cluster as **a room with a fixed number of chairs**. Everything in
the design — every pixel of the picture, and every learning neuron — needs its
own chair. They share the same room.

```
pixels + neurons  must fit in  one room
```

So a 128-chair room showing a 10×10 picture uses 100 chairs for pixels, leaving
**28** for neurons. Want more neurons? Two options, and only two:

- **A bigger room** — but room sizes must be 64, 128, 256, 512 or 1024.
- **More rooms** — this is what "wide" does, and it's what worked.

The room size must be a power of two because the memory is physically wired
that way. If you ask for a shape that can't fit, the tool refuses with a plain
message rather than building something broken:

```
196 inputs leaves no room for neurons in a 128-slot cluster;
raise --neurons-per-cluster to 256
```

### What fits

| Picture size | Pixels used | Room size | Neurons left over | Speed |
|---|---|---|---|---|
| 7×7 | 49 | 64 | 15 | very fast |
| 10×10 | 100 | 128 | 28 | a few hours |
| 14×14 | 196 | 256 | 60 | ~4× slower |
| 28×28 (full size) | 784 | 1024 | 240 | fits, but weeks |

Full-size MNIST **does fit the design** — 784 + 240 = 1024. Only the
simulator's speed stops us. On a real chip it would be fine.

### The dials

Add any of these to the end of a command. Anything you don't mention keeps its
default.

| Dial | Default | What it does |
|---|---|---|
| `MNIST_IMAGES` | 1200 | how many pictures (60% learn / 20% label / 20% test) |
| `MNIST_GRID` | 10 | picture size — 7, 10 or 14 |
| `MNIST_NEURONS` | 128 | chairs per room — must be 64, 128, 256, 512 or 1024 |
| `MNIST_CLUSTERS` | 4 | how many rooms |
| `MNIST_TIMESTEPS` | 20 | how long each picture is shown |
| `MNIST_THRESHOLD` | 1500 | how easily a neuron reacts — lower fires more |
| `MNIST_MAX_RATE` | 0.55 | how strongly a bright pixel shouts |
| `MNIST_SEED` | 1 | the randomness; change it to repeat a run differently |

### Recipes

```bash
# A quick taste — small pictures, few images, minutes not hours
make mnist_wide MNIST_GRID=7 MNIST_NEURONS=64 MNIST_IMAGES=200

# Twice the brain: 8 rooms instead of 4
make mnist_wide MNIST_CLUSTERS=8

# More neurons per room: a 256-chair room leaves 156 for neurons
make mnist_wide MNIST_NEURONS=256

# Is the winning result luck? Re-run with different randomness
make mnist_wide MNIST_SEED=7

# Nothing is firing? Make neurons more sensitive
make mnist_wide MNIST_THRESHOLD=900
```

### Testing the wiring on its own

To check that many rooms can talk to each other, without any learning:

```bash
make multi_cluster                    # 4 rooms
make multi_cluster MC_CLUSTERS=32     # 32 rooms = 1024 neurons
make multi_cluster_all                # tries 2, 4, 8 and 32
```

This is a hardware test, not an accuracy test — it finishes in seconds and
tells you the connections hold up at scale.

---

## 6. What we learned

| Attempt | Shape | Neurons | Score |
|---|---|---|---|
| One cluster | 1 room of 128 | 28 | 29.58% |
| **Wide** | **4 rooms of 128** | **112** | **41.67%** |
| Layered | 5 rooms of 64, two stages | 32 | 11.25% |
| Wide at 14×14 | 2 rooms of 256 | 120 | 32.92% |
| *Guessing* | — | — | *10.00%* |

**Wider beats deeper — clearly.** Going from 28 neurons to 112 lifted the score
by 12 points. More neurons looking at the same picture and voting is what
helped.

**Why the layered one failed.** It wasn't a bug — the hardware ran perfectly
and the first stage genuinely learned clean fragments of pen strokes. The
problem is that inside each room the neurons *compete*, and only one is allowed
to win at a time. So each of the four first-stage rooms passes on just one
answer. The whole picture gets squeezed down to about 12 bits before the second
stage ever sees it, and no amount of cleverness downstream can rebuild what was
thrown away. **Competition is useful inside a layer and destructive between
layers.**

**Why the higher-resolution one scored worse.** Not because 14×14 is a bad
idea — it was simply **undertrained**. The logs show it: neurons fired 14,543
times during learning versus 38,084 in the winning run, so each neuron got
about **121 learning events instead of 340**. Only 51 of 120 neurons ever woke
up at all, and the learned pictures came out nearly blank. It was given 2.4×
more pixels to make sense of but a third of the practice. Worth retrying with
more images and the timesteps back at 20.

**One stubborn problem.** Digits **4 and 5 score 0%** in every wide run. In the
best run, digit 5 was never assigned a single neuron — so it was impossible to
predict, structurally. Digit 4 had 13 neurons assigned and *still* got none
right; its neurons never won a competition when it counted. Interestingly,
digit *coverage* improved steadily across the runs (7 of 10 digits → 9 → all
10) even though accuracy peaked in the middle. Fixing 4 and 5 is the single
most promising next step.

---

## 7. Where things are

```
code/ip/03.learning-rule/stdp_engine/     <- everything lives here
├── rtl/       the chip design itself
├── tb/        the test harnesses that drive it
├── tools/     prepares the pictures, saves the runs
├── runs/      every past run, date-stamped, never overwritten
├── data/      the MNIST pictures
├── README.md      the technical version of this guide
└── DIAGNOSIS.md   every bug we found, with the evidence

attic/         parked clutter — nothing here runs, nothing is deleted
```

---

## 8. How good is this, honestly?

**What's genuinely impressive:**

- **It learns with nobody supervising it.** During learning it is never told
  what any picture is. It groups similar shapes by itself. Labels are attached
  afterwards, purely to score it.
- **The learning happens in the hardware.** No PC, no backpropagation, no
  training step. Connection strengths are updated by the circuit as the spikes
  arrive. This is the hard part, and it works.
- **It learned from 720 examples.** Conventional systems use tens of thousands.
- **It's real, synthesisable hardware** — not a Python model of hardware. It
  could go onto an FPGA.
- **It scales.** The multi-room wiring is tested up to 1024 neurons, and
  full-resolution MNIST fits the design.

**What it can't do yet — stated plainly:**

- **42% is a long way from solved.** Published research using this same family
  of learning rule reaches far higher with more neurons and far more training.
  Our result is a working *foundation*, not a competitive digit recogniser.
- **Two of the ten digits don't work at all.**
- **Simulation is painfully slow.** Hours per experiment is the single biggest
  brake on progress. Real hardware would remove it entirely.
- **The two-stage design is a dead end as built.** It needs a different way of
  passing information between layers before depth will help.

**The fair summary:** the hard, novel thing — a chip that rewires itself while
running, with no outside help — is built and demonstrably works. Turning it
into an accurate recogniser is the next phase, and the obvious moves are more
neurons, more training, and getting off the simulator.

---

## 9. When something goes wrong

| What you see | What it means |
|---|---|
| `iverilog: command not found` | Simulator not installed — section 2. |
| `missing data/mnist/...` | Run `make download_mnist`. |
| `excitatory spikes: 0` | Nothing fired. Lower `MNIST_THRESHOLD` to about 900. |
| `must be a power of 2` | Room size has to be 64, 128, 256, 512 or 1024. |
| `leaves no room for neurons` | Picture too big for the room — use a bigger `MNIST_NEURONS`. |
| Health line not all zeros | A real hardware fault. Ignore the score entirely. |
| Learned pictures all `####` | Connections maxed out — learning ran away. |
| Learned pictures blank | Those neurons never won. Usually undertrained. |
| It's been hours | Normal. Check progress with `tail -f runs/<newest>/run.log`. |

To start over cleanly:

```bash
make clean      # deletes build files; your saved runs/ are safe
```
