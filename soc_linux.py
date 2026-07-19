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
from migen.fhdl.decorators import ResetInserter
from migen.genlib.fifo import SyncFIFOBuffered

from litex.soc.interconnect.csr import *
from litex.build.generic_platform import Pins, Subsignal, IOStandard, Misc

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
    """32-bit SPI slave with an EBR-backed Linux receive queue.

    LiteX SPISlave owns pin sampling and clock-domain synchronization. Every
    complete, CS-delimited 32-bit transaction is enqueued in system-clock
    domain. Linux reads the head through rx_data and pops it with CONTROL_ACK,
    preserving the original mailbox CSR API while eliminating its one-word
    overrun limit.
    """

    RX_FIFO_DEPTH = 4096

    def __init__(self, pads, data_width):
        if data_width != 32:
            raise ValueError("SpiSlaveExt FIFO transport requires 32-bit words")

        self.submodules.spi = spi = SPISlave(pads, data_width=data_width)
        self.submodules.rx_fifo = rx_fifo = ResetInserter()(
            SyncFIFOBuffered(width=data_width, depth=self.RX_FIFO_DEPTH)
        )

        # Keep the original mailbox-facing register order stable. rx_data is
        # now the FIFO head and ACK pops exactly one queued word.
        self.rx_data = CSRStatus(
            data_width,
            description="Head of the SPI RX FIFO; valid while status bit0 is set.",
        )
        self.tx_data = CSRStorage(
            data_width,
            description="Word shifted out on MISO during subsequent SPI transactions.",
        )
        self.rx_length = CSRStatus(
            8,
            description="32 while an RX FIFO word is available, otherwise zero.",
        )
        self.status = CSRStatus(
            4,
            description=(
                "bit0=rx_fifo_readable, bit1=spi_busy, bit2=rx_overflow, "
                "bit3=invalid_transaction_length."
            ),
        )
        self.transaction_count = CSRStatus(
            32,
            description="Completed SPI transactions since clear/reset.",
        )
        self.control = CSRStorage(
            2,
            description=(
                "Write bit0=1 to pop one RX FIFO word; write bit1=1 to reset "
                "the FIFO, faults, diagnostics, and transaction counter."
            ),
        )

        # Raw/live diagnostic view. These remain at their existing CSR offsets.
        self.raw_mosi = CSRStatus(data_width, description="Live LiteX SPISlave MOSI shift register.")
        self.raw_length = CSRStatus(8, description="Live LiteX SPISlave bit counter.")
        self.raw_done = CSRStatus(1, description="Live LiteX SPISlave done/idle signal.")
        self.raw_pins = CSRStatus(
            4,
            description="Physical pins: bit0=cs_n bit1=clk bit2=mosi bit3=miso.",
        )
        self.raw_cs_assert_count = CSRStatus(32, description="Synchronized CS_N falling-edge count.")
        self.raw_cs_deassert_count = CSRStatus(32, description="Synchronized CS_N rising-edge count.")
        self.raw_sck_rise_count = CSRStatus(32, description="Synchronized raw SCK rising-edge count.")
        self.raw_sck_fall_count = CSRStatus(32, description="Synchronized raw SCK falling-edge count.")
        self.raw_mosi_high_on_sck_rise = CSRStatus(32, description="SCK rises with MOSI high.")
        self.raw_mosi_low_on_sck_rise = CSRStatus(32, description="SCK rises with MOSI low.")

        # New FIFO CSRs are appended after all legacy offsets.
        self.rx_fifo_level = CSRStatus(
            13,
            description="Number of unread 32-bit words in the SPI RX FIFO.",
        )
        self.rx_fifo_capacity = CSRStatus(
            13,
            description="Constant SPI RX FIFO capacity in 32-bit words.",
        )
        self.rx_dropped_count = CSRStatus(
            32,
            description="Transactions dropped due to overflow or non-32-bit length.",
        )

        rx_overflow = Signal(reset=0)
        invalid_length = Signal(reset=0)
        transaction_count_reg = Signal(32, reset=0)
        rx_dropped_count_reg = Signal(32, reset=0)

        raw_cs_meta = Signal(reset=1)
        raw_cs_sync = Signal(reset=1)
        raw_cs_prev = Signal(reset=1)
        raw_sck_meta = Signal(reset=0)
        raw_sck_sync = Signal(reset=0)
        raw_sck_prev = Signal(reset=0)
        raw_mosi_meta = Signal(reset=0)
        raw_mosi_sync = Signal(reset=0)

        raw_cs_assert_count_reg = Signal(32, reset=0)
        raw_cs_deassert_count_reg = Signal(32, reset=0)
        raw_sck_rise_count_reg = Signal(32, reset=0)
        raw_sck_fall_count_reg = Signal(32, reset=0)
        raw_mosi_high_count_reg = Signal(32, reset=0)
        raw_mosi_low_count_reg = Signal(32, reset=0)

        raw_cs_assert = Signal()
        raw_cs_deassert = Signal()
        raw_sck_rise = Signal()
        raw_sck_fall = Signal()

        done_d = Signal(reset=1)
        transaction_complete = Signal()

        # CSRStorage.storage is updated on the same edge that asserts re.
        # Capture it after that edge and fire once on the following cycle.
        control_re_d = Signal(reset=0)
        control_fire = Signal(reset=0)
        control_bits = Signal(2, reset=0)
        ack_pulse = Signal()
        clear_pulse = Signal()

        valid_word_complete = Signal()
        fifo_overflow_event = Signal()
        invalid_length_event = Signal()

        self.comb += [
            spi.miso.eq(self.tx_data.storage),

            transaction_complete.eq(~done_d & spi.done),
            valid_word_complete.eq(transaction_complete & (spi.length == data_width)),
            fifo_overflow_event.eq(valid_word_complete & ~rx_fifo.writable),
            invalid_length_event.eq(transaction_complete & (spi.length != data_width)),

            ack_pulse.eq(control_fire & control_bits[0]),
            clear_pulse.eq(control_fire & control_bits[1]),

            rx_fifo.din.eq(spi.mosi),
            rx_fifo.we.eq(valid_word_complete & rx_fifo.writable & ~clear_pulse),
            rx_fifo.re.eq(ack_pulse & rx_fifo.readable & ~clear_pulse),
            rx_fifo.reset.eq(clear_pulse),

            self.rx_data.status.eq(rx_fifo.dout),
            self.rx_length.status.eq(Mux(rx_fifo.readable, data_width, 0)),
            self.transaction_count.status.eq(transaction_count_reg),
            self.status.status.eq(Cat(
                rx_fifo.readable,
                ~spi.done,
                rx_overflow,
                invalid_length,
            )),
            self.rx_fifo_level.status.eq(rx_fifo.level),
            self.rx_fifo_capacity.status.eq(self.RX_FIFO_DEPTH),
            self.rx_dropped_count.status.eq(rx_dropped_count_reg),

            self.raw_mosi.status.eq(spi.mosi),
            self.raw_length.status.eq(spi.length),
            self.raw_done.status.eq(spi.done),
            self.raw_pins.status.eq(Cat(pads.cs_n, pads.clk, pads.mosi, pads.miso)),

            raw_cs_assert.eq(raw_cs_prev & ~raw_cs_sync),
            raw_cs_deassert.eq(~raw_cs_prev & raw_cs_sync),
            raw_sck_rise.eq(~raw_sck_prev & raw_sck_sync),
            raw_sck_fall.eq(raw_sck_prev & ~raw_sck_sync),

            self.raw_cs_assert_count.status.eq(raw_cs_assert_count_reg),
            self.raw_cs_deassert_count.status.eq(raw_cs_deassert_count_reg),
            self.raw_sck_rise_count.status.eq(raw_sck_rise_count_reg),
            self.raw_sck_fall_count.status.eq(raw_sck_fall_count_reg),
            self.raw_mosi_high_on_sck_rise.status.eq(raw_mosi_high_count_reg),
            self.raw_mosi_low_on_sck_rise.status.eq(raw_mosi_low_count_reg),
        ]

        self.sync += [
            control_re_d.eq(self.control.re),
            control_fire.eq(control_re_d),
            If(control_re_d,
                control_bits.eq(self.control.storage),
            ),

            done_d.eq(spi.done),

            raw_cs_meta.eq(pads.cs_n),
            raw_cs_sync.eq(raw_cs_meta),
            raw_cs_prev.eq(raw_cs_sync),
            raw_sck_meta.eq(pads.clk),
            raw_sck_sync.eq(raw_sck_meta),
            raw_sck_prev.eq(raw_sck_sync),
            raw_mosi_meta.eq(pads.mosi),
            raw_mosi_sync.eq(raw_mosi_meta),

            If(clear_pulse,
                rx_overflow.eq(0),
                invalid_length.eq(0),
                transaction_count_reg.eq(0),
                rx_dropped_count_reg.eq(0),
                raw_cs_assert_count_reg.eq(0),
                raw_cs_deassert_count_reg.eq(0),
                raw_sck_rise_count_reg.eq(0),
                raw_sck_fall_count_reg.eq(0),
                raw_mosi_high_count_reg.eq(0),
                raw_mosi_low_count_reg.eq(0),
            ).Else(
                If(raw_cs_assert,
                    raw_cs_assert_count_reg.eq(raw_cs_assert_count_reg + 1),
                ),
                If(raw_cs_deassert,
                    raw_cs_deassert_count_reg.eq(raw_cs_deassert_count_reg + 1),
                ),
                If(raw_sck_rise,
                    raw_sck_rise_count_reg.eq(raw_sck_rise_count_reg + 1),
                    If(raw_mosi_sync,
                        raw_mosi_high_count_reg.eq(raw_mosi_high_count_reg + 1),
                    ).Else(
                        raw_mosi_low_count_reg.eq(raw_mosi_low_count_reg + 1),
                    ),
                ),
                If(raw_sck_fall,
                    raw_sck_fall_count_reg.eq(raw_sck_fall_count_reg + 1),
                ),

                If(transaction_complete,
                    transaction_count_reg.eq(transaction_count_reg + 1),
                ),
                If(fifo_overflow_event,
                    rx_overflow.eq(1),
                    rx_dropped_count_reg.eq(rx_dropped_count_reg + 1),
                ).Elif(invalid_length_event,
                    invalid_length.eq(1),
                    rx_dropped_count_reg.eq(rx_dropped_count_reg + 1),
                ),
            ),
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
                    Subsignal("cs_n", Pins("N17"), Misc("PULLMODE=UP")),
                    Subsignal("clk",  Pins("N16")),
                    Subsignal("mosi", Pins("R17"), Misc("PULLMODE=UP")),
                    Subsignal("miso", Pins("N15"), Misc("PULLMODE=UP")),
                    IOStandard("LVCMOS33"),
                    Misc("SLEWRATE=SLOW"),
                )
            ])
            self.submodules.spi_ext = SpiSlaveExt(
                pads       = self.platform.request("spi_ext", 0),
                data_width = 32,  # shrunk from 2048 -- 256B framing now happens in software
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
