# Configurable Set-Associative Write-Back Cache

A modular Verilog implementation of a blocking, parameterized cache with
write-back/write-allocate behavior, tree pseudo-LRU replacement, and even
parity protection for tags. The core is verified with Icarus Verilog and
GTKWave and is intended for later implementation on a Zynq-7000 FPGA with
AMD Vivado.

The scope is deliberately appropriate for an undergraduate resume project:
the emphasis is complete behavior, focused modules, reproducible verification,
and measured FPGA results rather than additional cache features.

## Current Status

The complete cache datapath is integrated and simulation-verified. Implemented
components include:

- Synchronous tag and 32-bit data arrays
- Parity-aware tag comparator
- Direct-mapped, 2-way, and 4-way replacement logic
- Writeback buffer and blocking cache controller
- Variable-latency lower-memory model
- Processor-visible reference scoreboard
- Directed and randomized unit and integration tests
- Fixed-capacity 16 KiB regressions for every supported associativity
- Explicit validation of supported cache geometry

Tag parity remains part of the design. Per-word SECDED was intentionally
removed so the project has one complete, explainable data path and no unused
codec interfaces.

## Default Configuration

| Property | Default |
|---|---:|
| Data capacity | 16 KiB |
| Cache line | 32 bytes |
| Associativity | 4 ways |
| Processor data width | 32 bits |
| Write policy | Write-back, write-allocate |
| Replacement | Tree pseudo-LRU |
| Tag protection | Even parity |
| Outstanding requests | 1 |

Supported associativities are 1, 2, and 4 ways. Processor requests must be
aligned 32-bit reads or writes. The lower-memory interface transfers complete
256-bit cache lines.

## Scope

The project includes blocking request/response handling, invalid-way-first
victim selection, dirty-line writeback, bounded memory stalls, response
backpressure, tag-parity fault handling, lower-memory error handling, and
self-checking randomized tests.

It excludes MSHRs, hit-under-miss behavior, coherence, unaligned accesses,
partial writes, AXI integration, and data ECC.

## Tools

Current RTL verification uses:

- Verilog-2001 for synthesizable RTL
- Icarus Verilog and `vvp` for simulation
- GTKWave and VCD files for waveform inspection
- `svlint` plus compiler warnings for static checks
- Make and shell scripts for reproducible runs

The testbench uses an Icarus-compatible SystemVerilog subset. The later FPGA
flow uses AMD Vivado synthesis, implementation, timing, utilization, and power
reports for a Zynq-7000 target.

## Repository Layout

```text
.
|-- rtl/cache/          Core cache RTL and structural integration
|-- tb/common/          Reusable processor-visible checking infrastructure
|-- tb/models/          Variable-latency lower-memory model
|-- tb/tests/           Directed and randomized test tops
|-- fpga/rtl/           Planned Zynq wrapper and hardware self-test
|-- fpga/constraints/   Planned board and timing constraints
|-- fpga/tcl/           Planned reproducible Vivado scripts
|-- scripts/            Local workflow helpers
|-- docs/               Architecture and project plan
|-- build/              Ignored simulator outputs and waveforms
`-- reports/            Ignored regression and FPGA reports
```

Production RTL keeps one synthesizable module per file. `cache_top.v` is the
structural boundary; board-specific logic stays outside `rtl/`.

## Local Verification

Check installed tools:

```bash
make tools
```

Run a test:

```bash
make sim TOP=tb_smoke TEST=tb/tests/tb_smoke.sv SEED=1
```

Run the complete regression:

```bash
make regression
```

Each run writes per-case logs plus machine-readable summaries to:

```text
reports/regression/summary.csv
reports/regression/summary.jsonl
```

The records identify the test, associativity, tag-parity setting, seed,
pass/fail status, Git revision, Icarus version, geometry, log, and VCD.
Override the seed list with, for example, `make regression SEEDS="1 2 3"`.

Override associativity for the integrated smoke test:

```bash
make sim TOP=tb_smoke TEST=tb/tests/tb_smoke.sv \
  PARAMS=-Ptb_smoke.WAYS=2 SEED=2
```

Run the 4-way parity-disabled PPA comparison configuration directly with:

```bash
make sim TOP=tb_smoke TEST=tb/tests/tb_smoke.sv \
  PARAMS="-Ptb_smoke.WAYS=4 -Ptb_smoke.TAG_PARITY_ENABLE=0" SEED=2
```

The full regression includes this configuration automatically.

Open a generated waveform:

```bash
make wave WAVE=build/tb_smoke.vcd
```

Regenerate the documented waveform figures after a regression with:

```bash
make render-waves
```

Randomized tests print their seed so failures can be replayed.

## Remaining Work

1. Create the Zynq-7000 wrapper, deterministic hardware self-test, constraints,
   and batch Vivado flow.
2. Record post-route utilization, timing, and power results.
3. Program the target board and document the hardware demonstration.

The current published evidence is RTL simulation only. No FPGA frequency,
resource, power, or hardware-operation claim is made yet.

The frozen interfaces and timing contract are in
[docs/architecture.md](docs/architecture.md). The full remaining workflow is
in [docs/project_plan.md](docs/project_plan.md), and measured simulation results
are summarized in [docs/verification_results.md](docs/verification_results.md).

## Version Control

Changes are kept in small commits. A behaviorally complete RTL module and its
focused test belong together; documentation, build tooling, and generated
result summaries remain separate where practical.
