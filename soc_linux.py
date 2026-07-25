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
from litex.soc.interconnect.csr_eventmanager import EventManager, EventSourceLevel, EventSourcePulse
from litex.build.generic_platform import Pins, Subsignal, IOStandard, Misc

from litex.soc.cores.cpu.vexriscv_smp import VexRiscvSMP
from litex.soc.cores.gpio    import GPIOOut, GPIOIn
from litex.soc.cores.spi     import SPIMaster
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


# ASI continuous-CS SPI stream and CSR wrapper -------------------------------------------------------
#
# The sys-clock-domain sampler frames every 32 SPI mode-0 bits into the EBR
# FIFO. Linux polls the stable FIFO head and explicitly ACKs each word.

class SpiSlaveExt(Module, AutoCSR):
    """Continuous-CS SPI word framer with an EBR-backed Linux receive queue.

    The Tegra controller cannot provide a reliably observable CS-high interval
    between descriptors in one SPI_IOC_MESSAGE. This core therefore treats CS
    as a stream envelope and commits every complete group of 32 sampled bits as
    one FIFO word. CS may stay asserted across thousands of bits; a partial
    final word is rejected when CS deasserts.
    """

    RX_FIFO_DEPTH = 4096

    def __init__(self, pads, data_width):
        if data_width != 32:
            raise ValueError("SpiSlaveExt stream transport requires 32-bit words")

        self.submodules.rx_fifo = rx_fifo = ResetInserter()(
            SyncFIFOBuffered(width=data_width, depth=self.RX_FIFO_DEPTH)
        )

        # Preserve every existing CSR offset. New FIFO diagnostics remain
        # appended after the legacy raw diagnostics.
        self.rx_data = CSRStatus(
            data_width,
            description="Head of the SPI RX FIFO; valid while status bit0 is set.",
        )
        self.tx_data = CSRStorage(
            data_width,
            description="32-bit response repeated on MISO for each streamed word.",
        )
        self.rx_length = CSRStatus(
            8,
            description="32 while an RX FIFO word is available, otherwise zero.",
        )
        self.status = CSRStatus(
            4,
            description=(
                "bit0=rx_fifo_readable, bit1=spi_cs_active, bit2=rx_overflow, "
                "bit3=partial_word_at_cs_deassertion."
            ),
        )
        self.transaction_count = CSRStatus(
            32,
            description="Complete 32-bit SPI words framed since clear/reset.",
        )
        self.control = CSRStorage(
            2,
            description=(
                "Write bit0=1 to pop one RX FIFO word; write bit1=1 to reset "
                "the FIFO, framer, faults, diagnostics, and counters."
            ),
        )

        self.raw_mosi = CSRStatus(data_width, description="Live SPI stream receive shift register.")
        self.raw_length = CSRStatus(8, description="Bits collected in the current stream word.")
        self.raw_done = CSRStatus(1, description="One while synchronized CS_N is inactive.")
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
            description="Words dropped by overflow plus partial CS-delimited words.",
        )

        raw_cs_meta = Signal(reset=1)
        raw_cs_sync = Signal(reset=1)
        raw_cs_prev = Signal(reset=1)
        raw_sck_meta = Signal(reset=0)
        raw_sck_sync = Signal(reset=0)
        raw_sck_prev = Signal(reset=0)
        raw_mosi_meta = Signal(reset=0)
        raw_mosi_sync = Signal(reset=0)

        raw_cs_assert = Signal()
        raw_cs_deassert = Signal()
        raw_sck_rise = Signal()
        raw_sck_fall = Signal()
        cs_active = Signal()

        rx_shift = Signal(data_width, reset=0)
        tx_shift = Signal(data_width, reset=0)
        bit_count = Signal(max=data_width, reset=0)
        completed_word = Signal(data_width)
        word_complete = Signal()
        partial_word_event = Signal()
        fifo_overflow_event = Signal()

        rx_overflow = Signal(reset=0)
        invalid_length = Signal(reset=0)
        transaction_count_reg = Signal(32, reset=0)
        rx_dropped_count_reg = Signal(32, reset=0)

        raw_cs_assert_count_reg = Signal(32, reset=0)
        raw_cs_deassert_count_reg = Signal(32, reset=0)
        raw_sck_rise_count_reg = Signal(32, reset=0)
        raw_sck_fall_count_reg = Signal(32, reset=0)
        raw_mosi_high_count_reg = Signal(32, reset=0)
        raw_mosi_low_count_reg = Signal(32, reset=0)

        # CSRStorage.storage updates on the edge that asserts re. Delay and
        # capture the write so ACK and CLEAR are exactly one system-clock pulse.
        control_re_d = Signal(reset=0)
        control_fire = Signal(reset=0)
        control_bits = Signal(2, reset=0)
        ack_pulse = Signal()
        clear_pulse = Signal()

        self.comb += [
            cs_active.eq(~raw_cs_sync),
            raw_cs_assert.eq(raw_cs_prev & ~raw_cs_sync),
            raw_cs_deassert.eq(~raw_cs_prev & raw_cs_sync),
            raw_sck_rise.eq(~raw_sck_prev & raw_sck_sync),
            raw_sck_fall.eq(raw_sck_prev & ~raw_sck_sync),

            completed_word.eq(Cat(raw_mosi_sync, rx_shift[:data_width - 1])),
            word_complete.eq(cs_active & raw_sck_rise & (bit_count == data_width - 1)),
            partial_word_event.eq(raw_cs_deassert & (bit_count != 0)),
            fifo_overflow_event.eq(word_complete & ~rx_fifo.writable),

            ack_pulse.eq(control_fire & control_bits[0]),
            clear_pulse.eq(control_fire & control_bits[1]),

            rx_fifo.din.eq(completed_word),
            rx_fifo.we.eq(word_complete & rx_fifo.writable & ~clear_pulse),
            rx_fifo.re.eq(ack_pulse & rx_fifo.readable & ~clear_pulse),
            rx_fifo.reset.eq(clear_pulse),

            # SPI mode 0: present MSB before the rising sample edge and change
            # MISO only after synchronized falling edges.
            pads.miso.eq(tx_shift[data_width - 1]),

            self.rx_data.status.eq(rx_fifo.dout),
            self.rx_length.status.eq(Mux(rx_fifo.readable, data_width, 0)),
            self.transaction_count.status.eq(transaction_count_reg),
            self.status.status.eq(Cat(
                rx_fifo.readable,
                cs_active,
                rx_overflow,
                invalid_length,
            )),
            self.rx_fifo_level.status.eq(rx_fifo.level),
            self.rx_fifo_capacity.status.eq(self.RX_FIFO_DEPTH),
            self.rx_dropped_count.status.eq(rx_dropped_count_reg),

            self.raw_mosi.status.eq(rx_shift),
            self.raw_length.status.eq(bit_count),
            self.raw_done.status.eq(~cs_active),
            self.raw_pins.status.eq(Cat(pads.cs_n, pads.clk, pads.mosi, pads.miso)),
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

            raw_cs_meta.eq(pads.cs_n),
            raw_cs_sync.eq(raw_cs_meta),
            raw_cs_prev.eq(raw_cs_sync),
            raw_sck_meta.eq(pads.clk),
            raw_sck_sync.eq(raw_sck_meta),
            raw_sck_prev.eq(raw_sck_sync),
            raw_mosi_meta.eq(pads.mosi),
            raw_mosi_sync.eq(raw_mosi_meta),

            If(clear_pulse,
                rx_shift.eq(0),
                tx_shift.eq(self.tx_data.storage),
                bit_count.eq(0),
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
                    tx_shift.eq(self.tx_data.storage),
                    bit_count.eq(0),
                    raw_cs_assert_count_reg.eq(raw_cs_assert_count_reg + 1),
                ),
                If(raw_cs_deassert,
                    bit_count.eq(0),
                    raw_cs_deassert_count_reg.eq(raw_cs_deassert_count_reg + 1),
                ),

                If(cs_active & raw_sck_rise,
                    rx_shift.eq(completed_word),
                    If(bit_count == data_width - 1,
                        bit_count.eq(0),
                        transaction_count_reg.eq(transaction_count_reg + 1),
                    ).Else(
                        bit_count.eq(bit_count + 1),
                    ),
                    If(raw_mosi_sync,
                        raw_mosi_high_count_reg.eq(raw_mosi_high_count_reg + 1),
                    ).Else(
                        raw_mosi_low_count_reg.eq(raw_mosi_low_count_reg + 1),
                    ),
                ),

                If(cs_active & raw_sck_fall,
                    If(bit_count == 0,
                        tx_shift.eq(self.tx_data.storage),
                    ).Else(
                        tx_shift.eq(Cat(0, tx_shift[:data_width - 1])),
                    ),
                ),

                If(raw_sck_rise,
                    raw_sck_rise_count_reg.eq(raw_sck_rise_count_reg + 1),
                ),
                If(raw_sck_fall,
                    raw_sck_fall_count_reg.eq(raw_sck_fall_count_reg + 1),
                ),

                If(fifo_overflow_event,
                    rx_overflow.eq(1),
                    rx_dropped_count_reg.eq(rx_dropped_count_reg + 1),
                ),
                If(partial_word_event,
                    invalid_length.eq(1),
                    rx_dropped_count_reg.eq(rx_dropped_count_reg + 1),
                ),
            ),
        ]

        # Interrupt sources: a level line that stays asserted while the RX FIFO
        # holds at least one word (so the handler drains until empty and then
        # sleeps), plus a pulse for FIFO overflow.  This lets the Linux driver
        # sleep on the SPI IRQ instead of busy-polling the CSRs.
        self.submodules.ev = EventManager()
        self.ev.rx_available = EventSourceLevel(description="RX FIFO has at least one word.")
        self.ev.rx_overflow = EventSourcePulse(description="RX FIFO overflowed.")
        self.ev.finalize()
        self.comb += [
            self.ev.rx_available.trigger.eq(rx_fifo.readable),
            self.ev.rx_overflow.trigger.eq(fifo_overflow_event),
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
            self.irq.add("spi_ext")


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

                # Inject a device-tree node for the custom SpiSlaveExt mailbox.
                # litex_json2dts_linux does not know this peripheral, so it
                # emits the CSRs and the interrupt number but no bindable node.
                # The lolv_spi kernel driver binds to compatible="lolv,spi-ext";
                # reg is the spi_ext CSR window and interrupts is the PLIC line
                # LiteX assigned via self.irq.add("spi_ext") (read from csr.json
                # so a remap can never desync this from the hardware).
                spi_ext_irq = None
                try:
                    with open(json_src) as jf:
                        csr = json.load(jf)
                    spi_ext_irq = csr.get("constants", {}).get("spi_ext_interrupt")
                    if spi_ext_irq is None:
                        spi_ext_irq = csr.get("spi_ext_interrupt")
                except (OSError, ValueError):
                    spi_ext_irq = None
                if spi_ext_irq is not None and "spi-ext@f0005000" not in dts_content:
                    # Generated DTS uses space indentation: soc children at 12
                    # spaces, the soc node closing brace at 8 spaces.
                    spi_ext_node = (
                        "            spi_ext0: spi-ext@f0005000 {\n"
                        "                compatible = \"lolv,spi-ext\";\n"
                        "                reg = <0xf0005000 0x100>;\n"
                        f"                interrupts = <{int(spi_ext_irq)}>;\n"
                        "                status = \"okay\";\n"
                        "            };\n"
                    )
                    # The soc node closes with an 8-space '};' immediately before
                    # the top-level 'aliases {' block.  Insert our node just
                    # before that closing brace so it lands inside soc{}.
                    marker = "\n        aliases {"
                    idx = dts_content.find(marker)
                    if idx != -1:
                        close = dts_content.rfind("\n        };", 0, idx)
                        if close != -1:
                            dts_content = (
                                dts_content[:close] + "\n" + spi_ext_node
                                + dts_content[close:]
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
