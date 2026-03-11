# FPGA I2C Driver for MCP4725 DAC

> A synthesizable Verilog I2C master controller targeting the Microchip MCP4725 12-bit DAC, written for FPGA deployment.

---

## Table of Contents

- [Overview](#overview)
- [Hardware](#hardware)
- [Repository Structure](#repository-structure)
- [How It Works](#how-it-works)
  - [Module Interface](#module-interface)
  - [I2C Protocol & FSM](#i2c-protocol--fsm)
  - [SCL Clock Generator](#scl-clock-generator)
  - [SDA ACK Monitoring](#sda-ack-monitoring)
- [Byte Transmission Sequence](#byte-transmission-sequence)
- [Configuration Parameters](#configuration-parameters)
- [Getting Started](#getting-started)
- [Known Limitations & Future Work](#known-limitations--future-work)
- [References](#references)

---

## Overview

This project implements a complete I2C master in Verilog to drive the **MCP4725** 12-bit Digital-to-Analog Converter over a standard 100 kHz I2C bus. A 12-bit DAC value is loaded into the module and transmitted as a formatted 4-byte I2C write transaction (Fast Mode write to DAC register). The design targets Xilinx/Intel FPGAs but is written in plain, portable Verilog.

---

## Hardware

| Component | Details |
|-----------|---------|
| DAC | Microchip MCP4725 (SOT-23-6, I2C, 12-bit) |
| Interface | I2C — Standard Mode (100 kHz) |
| Default I2C Address | `0x60` (7-bit: `1100 000`) — A2=0, A1=0, A0=VSS |
| Supply | 2.7 V – 5.5 V |
| Output | 0 V to VDD (rail-to-rail) |

**Wiring:**

```
FPGA                MCP4725
------              --------
O_scl  ──[4.7kΩ]── SCL (pin 5)  ──── VDD
IO_sda ──[4.7kΩ]── SDA (pin 4)  ──── VDD
GND  ───────────── VSS (pin 2)
VDD  ───────────── VDD (pin 3)
                   A0  (pin 6)  ──── VSS   (sets address bit to 0)
                   VOUT (pin 1) ──── Analog output
```

> Both SCL and SDA are open-drain lines and **require pull-up resistors** (typically 4.7 kΩ for 100 kHz).

---

## Repository Structure

```
fpga-mcp4725-dac/
├── rtl/
│   └── dac.v               # Top-level I2C master + DAC driver
├── constraints/
│   └── pins.xdc            # Pin constraints (board-specific)
├── docs/
│   └── MCP4725_Datasheet.pdf
├── README.md
└── LICENSE
```

---

## How It Works

### Module Interface

```verilog
module dac(
    input        I_clk,        // System clock (e.g., 25 MHz)
    input        I_rst_n,      // Active-low reset — triggers a new transmission
    input [11:0] DAC_VALUE,    // 12-bit DAC code (0x000 – 0xFFF)
    output       O_scl,        // I2C clock output
    inout        IO_sda        // I2C data (bidirectional, open-drain)
);
```

`I_rst_n` going low initiates a complete I2C write cycle. When de-asserted (high), the FSM holds in the DONE state.

---

### I2C Protocol & FSM

The FSM progresses through 7 states to complete one full write transaction:

```
 ┌──────┐    ┌───────┐    ┌────────────┐    ┌───────────┐    ┌─────┐    ┌──────┐    ┌──────┐
 │ IDLE │───>│ START │───>│ LOAD BYTE  │───>│ SEND BYTE │───>│ ACK │───>│ STOP │───>│ DONE │
 └──────┘    └───────┘    └────────────┘    └───────────┘    └─────┘    └──────┘    └──────┘
                                                  ↑                 │ (if byte_cnt < 3)
                                                  └─────────────────┘
```

| State | ID | Description |
|-------|----|-------------|
| IDLE  | 0  | De-asserts SCL enable, clears counters |
| START | 1  | Enables SCL, pulls SDA low while SCL is high (I2C START condition) |
| LOAD BYTE | 2 | Loads the correct byte into `byte_data` based on `byte_cnt` |
| SEND BYTE | 3 | Shifts out 8 bits MSB-first, one bit per SCL cycle |
| ACK   | 4  | Provides the 9th clock pulse; increments byte counter |
| STOP  | 5  | Releases SDA high while SCL is high (I2C STOP condition) |
| DONE  | 6  | Holds idle after transaction completes |

---

### SCL Clock Generator

A free-running counter divides the system clock to produce the I2C SCL signal:

```verilog
parameter DIV = 8'd250;   // SCL half-period in system clock cycles
                          // For 25 MHz clock: 25e6 / (2 * 250) = 50 kHz
                          // Adjust DIV to match your system clock
```

The SCL line toggles every `DIV` clock cycles when `scl_en` is asserted. The FSM synchronises all state transitions to SCL edges (`scl_reg == 0/1 && scl_cnt == 0`) to ensure valid I2C setup and hold times are respected.

---

### SDA ACK Monitoring

After the 8th data bit, the master releases SDA (tri-states it) and provides the 9th clock pulse. During this pulse, the MCP4725 pulls SDA low to acknowledge. The design monitors SCL edges with a counter (`count`) to detect when the ACK window is active:

- `high_imp = 1` → FPGA drives SDA (data phase)
- `high_imp = 0` → SDA is released (tri-stated), allowing slave to ACK

> **Note:** The current design does not take action on a NACK — ACK monitoring is present for waveform correctness but error recovery is not yet implemented.

---

## Byte Transmission Sequence

The MCP4725 "Write DAC Register" command (C2=0, C1=1, C0=0, control byte = `0x40`) uses a 4-byte sequence:

```
Byte 0 (Address):   [1][1][0][0][0][0][0][W=0]  →  0xC0
Byte 1 (Control):   [0][1][0][0][0][0][0][0]    →  0x40  (Write DAC register, normal mode)
Byte 2 (MSB data):  DAC_VALUE[11:4]              →  upper 8 bits of 12-bit value
Byte 3 (LSB data):  DAC_VALUE[3:0] + [0000]      →  lower 4 bits, zero-padded
```

After the 4th ACK pulse, the MCP4725 updates its output voltage to:

```
VOUT = VDD × DAC_VALUE / 4096
```

---

## Configuration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `I2C_ADDR` | `7'd96` (0x60) | 7-bit I2C address of MCP4725 |
| `DIV` | `8'd250` | SCL half-period divider — set based on system clock |

**DIV calculation:**

```
DIV = F_clk / (2 × F_scl)

Examples:
  25 MHz clock, 100 kHz SCL  →  DIV = 125
  50 MHz clock, 100 kHz SCL  →  DIV = 250
 100 MHz clock, 100 kHz SCL  →  DIV = 500  (use wider counter)
```

---

## Getting Started

1. **Clone the repository**
   ```bash
   git clone https://github.com/<your-username>/fpga-mcp4725-dac.git
   cd fpga-mcp4725-dac
   ```

2. **Set your system clock frequency** — edit `DIV` in `rtl/dac.v` to match your board's clock.

3. **Set your I2C address** — check which A0/A1/A2 option your MCP4725 module uses and update `I2C_ADDR` accordingly.

4. **Add pin constraints** — map `O_scl`, `IO_sda`, `I_clk`, `I_rst_n`, and `DAC_VALUE` to your board's pins in `constraints/pins.xdc`.

5. **Synthesise and implement** using Vivado, Quartus, or your preferred tool.

6. **Drive the input** — set `DAC_VALUE[11:0]` to your desired 12-bit code and assert (pull low) `I_rst_n` momentarily to start a transmission.

---

## Known Limitations & Future Work

- [ ] ACK checking — currently no NACK error handling or retry logic
- [ ] Continuous/streaming mode — re-trigger on DAC_VALUE change without full reset
- [ ] EEPROM write support — implement C2=0, C1=1, C0=1 command for persistent storage
- [ ] Fast Mode (400 kHz) support — requires adjusting DIV and verifying timing margins

---

## References

- [MCP4725 Datasheet — Microchip Technology DS22039C](https://ww1.microchip.com/downloads/en/devicedoc/22039d.pdf)
- [I2C Bus Specification — NXP UM10204](https://www.nxp.com/docs/en/user-guide/UM10204.pdf)

---

## License

MIT License — see [LICENSE](LICENSE) for details.
