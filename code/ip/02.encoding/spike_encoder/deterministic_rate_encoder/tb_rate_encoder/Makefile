# Makefile for rate_encoder testbench
# Usage:
#   mingw32-make run
#   mingw32-make run TB=rate_encoder_tb_v1

IVERILOG = iverilog
VVP = vvp
GTKWAVE = gtkwave

TB_FILES = $(wildcard *_tb*.v)
TB_MODULES = $(basename $(TB_FILES))
TB ?= rate_encoder_tb_v1

RTL_RATE_ENCODER = $(abspath ../rtl/rate_encoder.v)
UTIL_DRE = $(abspath ../utils/deterministic_rate_encoder/deterministic_rate_encoder.v)
UTIL_COUNTER = $(abspath ../utils/encoder_counter/encoder_counter.v)
UTIL_EXTENDER = $(abspath ../utils/bit_extender_8_to_32/bit_extender_8_to_32.v)
UTIL_SPIKER = $(abspath ../utils/spiker/spiker.v)
TB_FILE = $(abspath $(TB).v)

SOURCES = "$(RTL_RATE_ENCODER)" \
          "$(UTIL_DRE)" \
          "$(UTIL_COUNTER)" \
          "$(UTIL_EXTENDER)" \
          "$(UTIL_SPIKER)" \
          "$(TB_FILE)"

EXECUTABLE = $(TB).out
WAVEFORM ?= $(TB).vcd

all: clean run

check-tb:
	@if "$(TB)"=="" (echo [ERROR] TB is empty. Use e.g. "mingw32-make run TB=rate_encoder_tb_v1" & exit /b 1)
	@echo $(TB_MODULES) | findstr /c:"$(TB)" >nul || (echo [ERROR] Unknown TB: $(TB) & echo Run "mingw32-make list-tb" to see available testbenches. & exit /b 1)

compile: check-tb
	@echo Compiling rate_encoder testbench...
	$(IVERILOG) -g2012 -o $(EXECUTABLE) $(SOURCES)
	@echo Compilation successful.

run: compile
	@echo.
	@echo Running testbench...
	@echo.
	$(VVP) $(EXECUTABLE)

list-tb:
	@echo Available testbenches: $(TB_MODULES)

view: check-tb
	@if not exist $(WAVEFORM) (echo [ERROR] Waveform file not found: $(WAVEFORM) & echo Run "mingw32-make run TB=$(TB)" first. & exit /b 1)
	$(GTKWAVE) $(WAVEFORM)

clean:
	@if exist *.out del /q *.out
	@if exist *.vcd del /q *.vcd
	@echo Cleaned.

help:
	@echo.
	@echo Targets:
	@echo   mingw32-make run [TB^=<tb_name^>]
	@echo   mingw32-make compile [TB^=<tb_name^>]
	@echo   mingw32-make list-tb
	@echo   mingw32-make view [TB^=<tb_name^>] [WAVEFORM^=<file.vcd^>]
	@echo   mingw32-make clean
	@echo.