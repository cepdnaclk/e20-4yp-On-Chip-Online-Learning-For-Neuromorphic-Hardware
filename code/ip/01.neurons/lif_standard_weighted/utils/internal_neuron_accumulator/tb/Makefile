# Makefile for Internal_neuron_accumulator testbenches
# Usage examples:
#   mingw32-make run
#   mingw32-make run TB=Internal_neuron_accumulator_tb_v1

# Tools
IVERILOG = iverilog
VVP      = vvp
GTKWAVE  = gtkwave

# Directories
DUT_DIR = ..

# Testbench selection
TB_FILES   = $(wildcard *_tb*.v)
TB_MODULES = $(basename $(TB_FILES))
TB ?= Internal_neuron_accumulator_tb_v1

# Source files
DUT_FILE = $(abspath $(DUT_DIR)/Internal_neuron_accumulator_v3.v)
TB_FILE  = $(abspath $(TB).v)

# Output files
EXECUTABLE = $(TB).out
WAVEFORM  ?= $(TB).vcd

# Default target
all: clean run

# Validate selected testbench
check-tb:
	@if "$(TB)"=="" (echo [ERROR] TB is empty. Use e.g. "mingw32-make run TB=Internal_neuron_accumulator_tb_v1" & exit /b 1)
	@echo $(TB_MODULES) | findstr /c:"$(TB)" >nul || (echo [ERROR] Unknown TB: $(TB) & echo Run "mingw32-make list-tb" to see available testbenches. & exit /b 1)

# Compile
compile: check-tb
	@echo Compiling $(TB)...
	$(IVERILOG) -g2012 -o $(EXECUTABLE) "$(DUT_FILE)" "$(TB_FILE)"
	@echo Compilation successful.

# Run simulation
run: compile
	@echo.
	@echo Running $(TB)...
	@echo.
	$(VVP) $(EXECUTABLE)

# Run every discovered testbench
run-all: $(TB_MODULES:%=run-%)

run-%:
	@$(MAKE) --no-print-directory run TB=$*

# List available testbenches
list-tb:
	@echo Available testbenches: $(TB_MODULES)

# Open waveform in GTKWave
view: check-tb
	@if not exist $(WAVEFORM) (echo [ERROR] Waveform not found: $(WAVEFORM) & echo Run "mingw32-make run TB=$(TB)" first. & exit /b 1)
	$(GTKWAVE) $(WAVEFORM)

# Clean generated files
clean:
	@if exist *.out del /q *.out
	@if exist *.vcd del /q *.vcd
	@echo Cleaned.

# Help
help:
	@echo.
	@echo Available targets:
	@echo   mingw32-make all                     - Clean, compile, and run (default)
	@echo   mingw32-make list-tb                 - List available testbenches
	@echo   mingw32-make compile TB^=<tb_name^>  - Compile selected testbench
	@echo   mingw32-make run TB^=<tb_name^>      - Compile and run selected testbench
	@echo   mingw32-make run-all                 - Run all testbenches
	@echo   mingw32-make view [WAVEFORM^=<file.vcd^>] - Open waveform in GTKWave
	@echo   mingw32-make clean                   - Remove generated files
	@echo   mingw32-make help                    - Show this help
	@echo.
	@echo Example:
	@echo   mingw32-make run TB=Internal_neuron_accumulator_tb_v1
	@echo.
