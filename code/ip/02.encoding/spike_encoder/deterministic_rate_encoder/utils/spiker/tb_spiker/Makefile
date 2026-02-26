# Makefile for Spiker Module Testbench
# Usage: make run

# Tools
IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

# Directories
SPIKER_DIR = ..
COUNTER_DIR = ../../encoder_counter

# Testbench selection
TB_FILES = $(wildcard *_tb*.v)
TB_MODULES = $(basename $(TB_FILES))
TB ?= spiker_tb

# Source files
SOURCES = $(COUNTER_DIR)/encoder_counter.v \
          $(SPIKER_DIR)/spiker.v \
		  $(TB).v

# Output
EXECUTABLE = $(TB).out
DEFAULT_WAVEFORM = $(TB).vcd
ifeq ($(TB),spiker_tb)
DEFAULT_WAVEFORM = spiker_waveform.vcd
endif
WAVEFORM ?= $(DEFAULT_WAVEFORM)

# Default target
all: clean run

# Validate selected testbench
check-tb:
	@if "$(TB)"=="" (echo [ERROR] TB is empty. Use e.g. "make run TB=spiker_tb_v2" & exit /b 1)
	@echo $(TB_MODULES) | findstr /c:"$(TB)" >nul || (echo [ERROR] Unknown TB: $(TB) & echo Run "make list-tb" to see available testbenches. & exit /b 1)

# Compile
compile: check-tb
	@echo Compiling testbench...
	$(IVERILOG) -o $(EXECUTABLE) $(SOURCES)
	@echo Compilation successful.

# Run
run: compile
	@echo.
	@echo Running testbench...
	@echo.
	$(VVP) $(EXECUTABLE)

run-all: $(TB_MODULES:%=run-%)

run-%:
	@$(MAKE) --no-print-directory run TB=$*

list-tb:
	@echo Available testbenches: $(TB_MODULES)

# View waveform
view: check-tb
	@if not exist $(WAVEFORM) (echo [ERROR] Waveform file not found: $(WAVEFORM) & echo Run "make run TB=$(TB)" first, or pass WAVEFORM=... & exit /b 1)
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
	@echo   make list-tb  - List availaviewble testbenches
	@echo   make compile TB=<tb_name> - Compile selected testbench
	@echo   make run TB=<tb_name>     - Compile and run selected testbench
	@echo   make run-all  - Run all testbenches
	@echo   make view [WAVEFORM=<file.vcd>] - Open waveform in GTKWave
	@echo   make clean    - Remove generated files
	@echo   make help     - Show this help
	@echo.
	@echo Examples:
	@echo   make run TB=spiker_tb
	@echo   make run TB=spiker_tb_v2
	@echo   make run-all
	@echo.
