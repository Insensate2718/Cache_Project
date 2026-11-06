SHELL := /bin/bash

TOP ?= tb_smoke
TEST ?= tb/tests/$(TOP).sv
SEED ?= 1
WAVE ?= build/$(TOP).vcd
PARAMS ?=
SEEDS ?= 1 17 20260802

.DEFAULT_GOAL := help

.PHONY: help tools sim check-params regression render-waves wave list clean

help:
	@printf '%s\n' \
		"Cache controller development targets:" \
		"  make tools                         Check Icarus, vvp, and GTKWave" \
		"  make sim TOP=<top> TEST=<file>     Compile and run one test" \
		"  make check-params                  Check accepted/rejected cache geometry" \
		"  make regression                    Run focused and 1/2/4-way tests" \
		"  make render-waves                  Render documented GTKWave figures" \
		"  make wave WAVE=<file.vcd>          Open a generated waveform" \
		"  make list                          List current RTL and testbench sources" \
		"  make clean                         Remove generated outputs" \
		"" \
		"Optional simulation variables:" \
		"  SEED=<integer>                     Reproducible random seed (default: 1)" \
		"  WAVE=<path.vcd>                    VCD output path" \
		"  PARAMS='<iverilog -P options>'      Top-level parameter overrides"

tools:
	@./scripts/check_tools.sh

sim: tools
	@TOP="$(TOP)" TEST="$(TEST)" SEED="$(SEED)" WAVE="$(WAVE)" \
		PARAMS="$(PARAMS)" \
		./scripts/run_sim.sh

check-params: tools
	@./scripts/check_parameters.sh

regression: tools check-params
	@SEEDS="$(SEEDS)" ./scripts/run_regression.sh

render-waves: tools
	@./scripts/render_waveforms.sh

wave:
	@test -f "$(WAVE)" || { \
		printf 'Waveform not found: %s\n' "$(WAVE)" >&2; \
		exit 2; \
	}
	@gtkwave "$(WAVE)"

list:
	@find rtl tb -type f \( -name '*.v' -o -name '*.sv' \) -print | sort

clean:
	@find build -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -delete
	@find reports -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -delete
