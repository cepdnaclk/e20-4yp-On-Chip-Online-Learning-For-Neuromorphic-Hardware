# Build Directory

This directory contains simulation artifacts, build outputs, and generated files.

## Contents

- **Waveform files** (`.vcd`, `.fst`): Signal dumps from simulations
- **Log files** (`.log`): Simulation and synthesis logs
- **Compiled modules**: Intermediate compilation outputs
- **Test results**: Output data from testbenches

## Note

This directory is typically auto-generated during the build process. Files here are temporary and can be safely deleted.

Add this directory to `.gitignore` to avoid committing build artifacts to version control.

## Cleanup

To clean build artifacts:
```bash
make clean
```

Or manually remove all files:
```bash
rm -rf build/*
```
