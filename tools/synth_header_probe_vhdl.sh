#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p gateware

if ! command -v yosys-ghdl >/dev/null 2>&1; then
  echo "ERROR: yosys-ghdl wrapper not found in PATH." >&2
  echo "Run:" >&2
  echo "  source ~/1tb/ext/fpga-env.sh" >&2
  echo "  hash -r" >&2
  echo "  which yosys-ghdl" >&2
  exit 1
fi

echo "using yosys-ghdl: $(command -v yosys-ghdl)"
yosys-ghdl -p 'help ghdl' >/tmp/header_probe_yosys_ghdl_help.log

echo "synthesizing gateware/header_probe.vhd -> gateware/header_probe.v"
yosys-ghdl -p '
  ghdl --std=08 gateware/header_probe.vhd -e header_probe
  write_verilog -noattr gateware/header_probe.v
'

echo
echo "generated gateware/header_probe.v:"
grep -nE 'module header_probe|inout|out_value|in_value|gpio|assign' gateware/header_probe.v | head -120
