# Makefile for Spiker Module Testbench
# Usage: make run

# Tools
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Directories
SPIKER_DIR = ..
COUNTER_DIR = ../../encoder_counter

# Source files
SOURCES = $(COUNTER_DIR)/encoder_counter.v \
          $(SPIKER_DIR)/spiker.v \
          spiker_tb.v

# Output
EXECUTABLE = spiker_tb.out
WAVEFORM = spiker_waveform.vcd

# Default target
all: clean run

# Compile
compile:
	@echo Compiling testbench...
	$(IVERILOG) -o $(EXECUTABLE) $(SOURCES)
	@echo Compilation successful.

# Run
run: compile
	@echo.
	@echo Running testbench...
	@echo.
	$(VVP) $(EXECUTABLE)

# View waveform
view:
	$(GTKWAVE) $(WAVEFORM)

# Clean
clean:
	@if exist $(EXECUTABLE) del $(EXECUTABLE)
	@if exist $(WAVEFORM) del $(WAVEFORM)
	@echo Cleaned.

# Help
help:
	@echo.
	@echo Available targets:
	@echo   make all      - Clean, compile, and run (default)
	@echo   make compile  - Compile only
	@echo   make run      - Compile and run testbench
	@echo   make view     - Open waveform in GTKWave
	@echo   make clean    - Remove generated files
	@echo   make help     - Show this help
	@echo.
