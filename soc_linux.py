#
# This file is part of Linux-on-LiteX-VexRiscv
#
# Copyright (c) 2019-2024, Linux-on-LiteX-VexRiscv Developers
# SPDX-License-Identifier: BSD-2-Clause

import os
import json
import shutil
import subprocess

from migen import *

from litex.soc.interconnect.csr import *
from litex.build.generic_platform import Pins, IOStandard, Misc

from litex.soc.cores.cpu.vexriscv_smp import VexRiscvSMP
from litex.soc.cores.gpio    import GPIOOut, GPIOIn
from litex.soc.cores.spi     import SPIMaster, SPISlave
from litex.soc.cores.bitbang import I2CMaster
from litex.soc.cores.pwm     import PWM

from litex.tools.litex_json2dts_linux import generate_dts




# Header Probe VHDL CSR wrapper --------------------------------------------------------------------

class HeaderProbe(Module, AutoCSR):
    def __init__(self, platform, pads):
        self.enable  = CSRStorage(1,  reset=0,     description="Enable header probe output drivers.")
        self.oe      = CSRStorage(12, reset=0x000, description="Output-enable mask for header probe pins.")
        self.out     = CSRStorage(12, reset=0x000, description="Output value mask for header probe pins.")
        self.pins_in = CSRStatus(12,              description="Live sampled value of header probe pins.")

        pins_in = Signal(12)

        platform.add_source("gateware/header_probe.v")

        self.specials += Instance("header_probe",
            i_clk       = ClockSignal("sys"),
            i_rst       = ResetSignal("sys"),

            i_enable    = self.enable.storage,
            i_oe        = self.oe.storage,
            i_out_value = self.out.storage,
            o_in_value  = pins_in,

            io_gpio     = pads,
        )

        self.comb += self.pins_in.status.eq(pins_in)


# SPI Slave Ext CSR wrapper -------------------------------------------------------------------------
#
# Thin CSR shim around LiteX's existing litex.soc.cores.spi.SPISlave core --
# same pattern as HeaderProbe, just wrapping an already-written module
# instead of custom VHDL. No IRQ for v1 (kept boring per basic_readme.md);
# Linux polls `done`/`length` via CSR.

class SpiSlaveExt(Module, AutoCSR):
    def __init__(self, pads, data_width):
        self.submodules.spi = spi = SPISlave(pads, data_width=data_width)

        self.mosi   = CSRStatus(data_width,  description="Last received MOSI data.")
        self.miso   = CSRStorage(data_width, description="Data to shift out as MISO on next transaction.")
        self.length = CSRStatus(8,            description="Length of last transaction, in bits.")
        self.done   = CSRStatus(1,            description="Transaction done/idle.")

        self.comb += [
            spi.miso.eq(self.miso.storage),
            self.mosi.status.eq(spi.mosi),
            self.length.status.eq(spi.length),
            self.done.status.eq(spi.done),
        ]


# SoCLinux -----------------------------------------------------------------------------------------

def SoCLinux(soc_cls, **kwargs):
    class _SoCLinux(soc_cls):
        def __init__(self, **kwargs):

            video_framebuffer_fifo_depth = kwargs.pop("video_framebuffer_fifo_depth", None)
            if isinstance(video_framebuffer_fifo_depth, str):
                video_framebuffer_fifo_depth = int(video_framebuffer_fifo_depth, 0)
            self.video_framebuffer_fifo_depth = video_framebuffer_fifo_depth

            # SoC ----------------------------------------------------------------------------------

            soc_cls.__init__(self, cpu_type="vexriscv_smp", cpu_variant="linux", **kwargs)

            # Header Probe -------------------------------------------------------------------------
            #
            # Real CSR-backed VHDL IP block for probing the OrangeCrab 0.1 inch GPIO holes from Linux.
            # This replaces the fake/manual DT-only gpio@f0004800 experiment.
            #
            # Bit mapping:
            #   bit 0  -> GPIO:1
            #   bit 1  -> GPIO:5
            #   bit 2  -> GPIO:6
            #   bit 3  -> GPIO:9
            #   bit 4  -> GPIO:10
            #   bit 5  -> GPIO:11
            #   bit 6  -> GPIO:12
            #   bit 7  -> GPIO:13
            #   bit 8  -> GPIO:18
            #   bit 9  -> GPIO:19
            #   bit 10 -> GPIO:20
            #   bit 11 -> GPIO:21
            #
            # GPIO:2/GPIO:3 are left alone because this SoC already has i2c0.
            self.platform.add_extension([
                ("header_probe_pads", 0,
                    Pins("GPIO:1 GPIO:5 GPIO:6 GPIO:9 GPIO:10 GPIO:11 GPIO:12 GPIO:13 GPIO:18 GPIO:19 GPIO:20 GPIO:21"),
                    IOStandard("LVCMOS33"),
                    Misc("PULLMODE=DOWN")
                )
            ])
            self.submodules.header_probe = HeaderProbe(
                platform = self.platform,
                pads     = self.platform.request("header_probe_pads", 0),
            )
            # Keep header_probe away from CSR bank 0.
            # Linux's litex_soc_ctrl driver expects the SoC controller/scratch CSR at 0xf0000000.
            # Bank 9 gives header_probe base 0xf0004800 with the default 0x800 CSR paging.
            self.csr.add("header_probe", n=9)

            # Header GPIO pins on the OrangeCrab 0.1" holes.
            #
            # Bit mapping:
            #   bit 0  -> GPIO:1
            #   bit 1  -> GPIO:5
            #   bit 2  -> GPIO:6
            #   bit 3  -> GPIO:9
            #   bit 4  -> GPIO:10
            #   bit 5  -> GPIO:11
            #   bit 6  -> GPIO:12
            #   bit 7  -> GPIO:13
            #   bit 8  -> GPIO:18
            #   bit 9  -> GPIO:19
            #   bit 10 -> GPIO:20
            #   bit 11 -> GPIO:21
            #
            # GPIO:2/GPIO:3 are left alone because this SoC already has i2c0.
            # GPIO:0/GPIO:14/GPIO:15/GPIO:16 are left alone for possible SPI-style use.

            # SPI Slave (Jetson<->OrangeCrab realtime link) -------------------------------------
            #
            # Dedicated pins reserved above:
            #   GPIO:0  (N17) -> cs_n
            #   GPIO:14 (N15) -> miso
            #   GPIO:15 (R17) -> mosi
            #   GPIO:16 (N16) -> clk
            #
            # 256-byte (2048-bit) transactions.
            self.platform.add_extension([
                ("spi_ext", 0,
                    Subsignal("cs_n", Pins("N17")),
                    Subsignal("clk",  Pins("N16")),
                    Subsignal("mosi", Pins("R17")),
                    Subsignal("miso", Pins("N15")),
                    IOStandard("LVCMOS33"),
                    Misc("PULLMODE=UP"),
                )
            ])
            self.submodules.spi_ext = SpiSlaveExt(
                pads       = self.platform.request("spi_ext", 0),
                data_width = 256 * 8,
            )
            # Keep spi_ext away from CSR bank 0 (ctrl) and bank 9 (header_probe).
            self.csr.add("spi_ext", n=10)


        # RGB Led ----------------------------------------------------------------------------------

        def add_rgb_led(self):
            rgb_led_pads = self.platform.request("rgb_led", 0)
            for n in "rgb":
                self.add_module(name=f"rgb_led_{n}0", module=PWM(getattr(rgb_led_pads, n)))

        # Switches ---------------------------------------------------------------------------------

        def add_switches(self):
            self.switches = GPIOIn(Cat(self.platform.request_all("user_sw")), with_irq=True)
            self.irq.add("switches")

        # SPI --------------------------------------------------------------------------------------

        def add_spi(self, data_width, clk_freq):
            spi_pads = self.platform.request("spi")
            self.spi = SPIMaster(spi_pads, data_width, self.clk_freq, clk_freq)

        # I2C --------------------------------------------------------------------------------------

        def add_i2c(self):
            self.i2c0 = I2CMaster(self.platform.request("i2c", 0))

        # Video ------------------------------------------------------------------------------------

        def add_video_framebuffer(self, *args, **kwargs):
            if self.video_framebuffer_fifo_depth is not None and len(args) < 6 and "fifo_depth" not in kwargs:
                kwargs["fifo_depth"] = self.video_framebuffer_fifo_depth
            return soc_cls.add_video_framebuffer(self, *args, **kwargs)

        # DTS generation ---------------------------------------------------------------------------

        def generate_dts(
            self,
            board_name,
            rootfs      = "ram0",
            nfs_server  = None,
            nfs_root    = None,
            nfs_options = None,
        ):
            json_src = os.path.join("build", board_name, "csr.json")
            dts = os.path.join("build", board_name, "{}.dts".format(board_name))
            if rootfs == "ram0":
                initrd = os.path.join("images", "rootfs.cpio.gz")
                if not os.path.exists(initrd):
                    initrd = "enabled"
            else:
                initrd = "disabled"

            with open(json_src) as json_file, open(dts, "w") as dts_file:
                dts_content = generate_dts(json.load(json_file),
                    initrd      = initrd,
                    polling     = False,
                    root_device = rootfs
                )
                if rootfs == "nfs":
                    if nfs_server is None or nfs_root is None:
                        raise ValueError("nfs_server and nfs_root are required for NFS rootfs")
                    nfsroot = f"{nfs_server}:{nfs_root}"
                    if nfs_options:
                        nfsroot += f",{nfs_options}"
                    dts_content = dts_content.replace(
                        "rootwait root=/dev/nfs",
                        f"root=/dev/nfs nfsroot={nfsroot}",
                    )
                dts_file.write(dts_content)

        # DTS compilation --------------------------------------------------------------------------

        def compile_dts(self, board_name, symbols=False):
            dts = os.path.join("build", board_name, "{}.dts".format(board_name))
            dtb = os.path.join("build", board_name, "{}.dtb".format(board_name))
            subprocess.check_call(
                "dtc {} -O dtb -o {} {}".format("-@" if symbols else "", dtb, dts), shell=True)

        # DTB combination --------------------------------------------------------------------------

        def combine_dtb(self, board_name, overlays=""):
            dtb_in = os.path.join("build", board_name, "{}.dtb".format(board_name))
            dtb_out = os.path.join("images", "rv32.dtb")
            if overlays == "":
                shutil.copyfile(dtb_in, dtb_out)
            else:
                subprocess.check_call(
                    "fdtoverlay -i {} -o {} {}".format(dtb_in, dtb_out, overlays), shell=True)

        # Documentation generation -----------------------------------------------------------------
        def generate_doc(self, board_name):
            from litex.soc.doc import generate_docs
            doc_dir = os.path.join("build", board_name, "doc")
            generate_docs(self, doc_dir)
            os.system("sphinx-build -M html {}/ {}/_build".format(doc_dir, doc_dir))

    return _SoCLinux(**kwargs)
