# Project 34: Multi-Protocol Market Data Parser

This project is part of a complete end-to-end trading system:
- **Main Repository:** [fpga-trading-systems](https://github.com/adilsondias-engineer/fpga-trading-systems)
- **Project Number:** 34 of 38 (for now, more to come)
- **Category:** FPGA Core 
- **Dependencies:**  Project 33 - Custom 10GBASE-R PHY (VHDL)

---


**Platform:** Xilinx Kintex-7 (XC7K325T on ALINX AX7325B)
**Technology:** Pure VHDL, custom TCP/UDP/SBE parsing
**Status:** Hardware verified - WNS +0.922ns, 0 critical warnings, NASDAQ + ASX operational, B3 SBE planned
**Role:** FPGA1 in 3-FPGA Trading Appliance Architecture  [planned]
**Protocols:** NASDAQ ITCH (UDP), ASX ITCH (TCP), B3 UMDF/SBE (UDP multicast) [planned]

---

## Overview

FPGA1 Network Ingress module for the 3-FPGA trading appliance. Implements multi-protocol market data parsing supporting NASDAQ (UDP/MoldUDP64), ASX (TCP/SoupBinTCP), and B3 Brazilian Exchange (UDP/SBE) market data feeds. Integrates with Project 33's 10GBASE-R PHY for 10GbE reception and outputs parsed messages via Aurora to FPGA2 (order book engine). Designed as an extensible protocol framework -- adding new exchanges requires only a new parser module and protocol demux entry.

**3-FPGA Architecture Role:**
```
Market Data (10GbE) -> [FPGA1: This Project] -> Aurora -> [FPGA2: Order Book] -> Aurora -> [FPGA3: Strategy]
```

**Key Features:**
- 10GBASE-R PHY integration (Project 33)
- XGMII MAC/IP parser for 10GbE
- TCP segment parser with sequence number tracking
- SoupBinTCP session layer handler (heartbeat, login, data)
- ASX ITCH message parser (adapted from NASDAQ ITCH)
- Protocol demultiplexer for UDP/TCP routing
- Message multiplexer (combines all protocol streams)
- Aurora TX interface to FPGA2 (order book engine)
- Maintains existing NASDAQ ITCH (UDP) compatibility

**Planned (B3 SBE):**
- SBE message header decoder (schema-driven binary encoding)
- Repeating group iterator FSM (variable-count MDEntries)
- Decimal64 price decoder (IEEE 754 → fixed-point)
- UMDF MarketDataIncrementalRefresh parser (TemplateId=50)
- Little-endian field extraction (B3 uses LE, unlike ITCH BE)
- See: [B3 SBE Integration Plan](../B3_SBE_INTEGRATION_PLAN.md)

---

## Architecture

### FPGA1 Internal Pipeline
```
  10GbE SFP+                                                       Aurora TX
      │                                                               │
      ▼                                                               │
┌─────────────────────────────────────────────────────────────────────┼────────┐
│ FPGA1: Network Ingress (fpga1_network_top.vhd)                      │        │
│                                                                     │        │
│  ┌──────────────┐                                                   │        │
│  │ 10GBASE-R    │    XGMII (64-bit @ 161.13 MHz)                    │        │
│  │ PHY          │──────────────┐                                    │        │
│  │ (Project 33) │              │                                    │        │
│  └──────────────┘              ▼                                    │        │
│                      ┌────────────────────┐                         │        │
│                      │ MAC/IP Parser      │                         │        │
│                      │ (mac_parser_xgmii) │                         │        │
│                      └─────────┬──────────┘                         │        │
│                                │ IP Payload + Protocol              │        │
│                      ┌─────────┴──────────┐                         │        │
│                      │   Protocol Demux   │                         │        │
│                      │  UDP(17) / TCP(6)  │                         │        │
│                      └─────────┬──────────┘                         │        │
│                                │                                    │        │
│              ┌─────────────────┼─────────────────┐                  │        │
│              │                 │                 │                  │        │
│              ▼                 ▼                 ▼                  │        │
│    ┌─────────────────┐ ┌─────────────────┐                         │        │
│    │ UDP Path        │ │ TCP Path        │                         │        │
│    │ (MoldUDP64)     │ │ (SoupBinTCP)    │                         │        │
│    │                 │ │                 │                         │        │
│    │ ┌─────────────┐ │ │ ┌─────────────┐ │                         │        │
│    │ │NASDAQ ITCH  │ │ │ │TCP Parser   │ │                         │        │
│    │ │Parser       │ │ │ └──────┬──────┘ │                         │        │
│    │ │(Project 23) │ │ │        ▼        │                         │        │
│    │ └──────┬──────┘ │ │ ┌─────────────┐ │                         │        │
│    │        │        │ │ │SoupBinTCP   │ │                         │        │
│    └────────┼────────┘ │ │Handler      │ │                         │        │
│             │          │ └──────┬──────┘ │                         │        │
│             │          │        ▼        │                         │        │
│             │          │ ┌─────────────┐ │                         │        │
│             │          │ │ASX ITCH     │ │                         │        │
│             │          │ │Parser       │ │                         │        │
│             │          │ └──────┬──────┘ │                         │        │
│             │          └────────┼────────┘                         │        │
│             │                   │                                  │        │
│             └─────────┬─────────┘                                  │        │
│                       │ Parsed Messages                            │        │
│             ┌─────────┴─────────┐                                  │        │
│             │   Message Mux     │                                  │        │
│             │ (NASDAQ + ASX)    │                                  │        │
│             └─────────┬─────────┘                                  │        │
│                       │                                            │        │
│             ┌─────────┴─────────┐                                  │        │
│             │   Aurora TX       │──────────────────────────────────┘        │
│             │   Wrapper         │                                           │
│             └───────────────────┘                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                              │
                                              ▼
                                    ┌─────────────────┐
                                    │ FPGA2: Order    │
                                    │ Book Engine     │
                                    │ (No Ethernet)   │
                                    └─────────────────┘
```

### Protocol Stack
```
                          Ethernet Frame
                                │
                                ▼
                    ┌───────────────────────┐
                    │     IP Parser         │
                    │  (Protocol Field)     │
                    └───────────┬───────────┘
                                │
                    ┌───────────┴───────────┐
                    │   Protocol Demux      │
                    │  UDP(17) vs TCP(6)    │
                    └───────────┬───────────┘
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                 │
              ▼                 ▼                 ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
    │   UDP Parser    │ │   TCP Parser    │ │   (Future)      │
    │  (MoldUDP64)    │ │  (SoupBinTCP)   │ │                 │
    └────────┬────────┘ └────────┬────────┘ └─────────────────┘
             │                   │
             │                   ▼
             │          ┌─────────────────┐
             │          │ SoupBinTCP      │
             │          │ Session Handler │
             │          └────────┬────────┘
             │                   │
             ▼                   ▼
    ┌─────────────────┐ ┌─────────────────┐
    │  NASDAQ ITCH    │ │   ASX ITCH      │
    │    Parser       │ │    Parser       │
    │  (Project 23)   │ │   (New)         │
    └────────┬────────┘ └────────┬────────┘
             │                   │
             └─────────┬─────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  Message Mux    │
              │  + Aurora TX    │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │  FPGA2 Order    │
              │  Book Engine    │
              └─────────────────┘
```

---

## Protocol Comparison

| Feature | NASDAQ ITCH 5.0 | ASX ITCH | B3 SBE (UMDF) |
|---------|-----------------|----------|---------------|
| Transport | MoldUDP64 (UDP) | SoupBinTCP (TCP) | UDP Multicast |
| Encoding | Fixed binary | Fixed binary | Schema-driven binary (SBE) |
| Symbol ID | Stock Locate (16-bit) | Order Book ID (32-bit) | SecurityID (64-bit) |
| Price Format | Fixed-point (4 dec) | Dynamic (per instrument) | Decimal64 (IEEE 754) |
| Byte Order | Big-endian | Big-endian | Little-endian |
| Message Types | 23 types | ~20 types | ~10 types (TemplateId) |
| Repeating Groups | No | No | Yes (MDEntries) |
| Variable Fields | No | No | Yes (length-prefixed) |
| Parser Complexity | ~500 LUTs | ~500 LUTs | ~1,500 LUTs (estimated) |
| Status | **Complete** | **Complete** | **Planned** |

---

## Components

### TCP Parser (`tcp/tcp_parser.vhd`)
- Parses TCP header from IP payload
- Extracts sequence number, ack number, flags
- Validates checksum (optional)
- Outputs TCP payload to session handler

### SoupBinTCP Handler (`transport/soupbintcp_handler.vhd`)
- Session layer for ASX ITCH/OUCH
- Message types: Login, Heartbeat, Sequenced Data, Unsequenced Data
- Automatic heartbeat response
- Sequence number tracking for gap detection

### ASX ITCH Parser (`itch/asx_itch_parser.vhd`)
- Adapted from NASDAQ ITCH parser
- 32-bit Order Book ID support
- Dynamic price decimal handling
- ASX-specific message types

### Protocol Demux (`common/protocol_demux.vhd`)
- Routes IP packets based on protocol field and destination port
- UDP (17), port 12345 -> MoldUDP64 -> NASDAQ ITCH
- TCP (6) -> SoupBinTCP -> ASX ITCH
- UDP (17), B3 multicast group -> SBE -> B3 UMDF (planned)

### B3 SBE Parser (planned - `sbe/`)
- `sbe_header_decoder.vhd` - 8-byte SBE message header (BlockLength, TemplateId, SchemaId, Version)
- `sbe_group_iterator.vhd` - Repeating group FSM (numInGroup entries × blockLength bytes)
- `decimal64_decoder.vhd` - IEEE 754 decimal64 → fixed-point price conversion
- `umdf_incremental_parser.vhd` - MarketDataIncrementalRefresh (TemplateId=50) MDEntry extraction
- See: [B3 SBE Integration Plan](../B3_SBE_INTEGRATION_PLAN.md)

---

## SoupBinTCP Message Format

| Type | Name | Size | Description |
|------|------|------|-------------|
| + | Debug | Variable | Debug message |
| A | Login Accepted | 30 | Session established |
| H | Server Heartbeat | 1 | Keep-alive from server |
| J | Login Rejected | 2 | Authentication failed |
| S | Sequenced Data | Variable | ITCH message payload |
| Z | End of Session | 1 | Session terminated |

### SoupBinTCP Packet Structure
```
┌────────────────────────────────────────┐
│ Packet Length (2 bytes, big-endian)    │
├────────────────────────────────────────┤
│ Packet Type (1 byte)                   │
├────────────────────────────────────────┤
│ Payload (variable)                     │
└────────────────────────────────────────┘
```

---

## ASX ITCH Message Types

### Reference Data (Start of Day)
| Type | Name | Size | Key Difference from NASDAQ |
|------|------|------|---------------------------|
| R | Order Book Directory | 57 | 32-bit Order Book ID, decimal info |
| L | Tick Size | 22 | Tick size table |
| O | Order Book State | 10 | Trading state |

### Order Messages (Real-time)
| Type | Name | Size | Key Difference from NASDAQ |
|------|------|------|---------------------------|
| A | Add Order | 39 | 32-bit Order Book ID, 8-byte qty |
| E | Order Executed | 31 | Similar structure |
| X | Order Cancel | 19 | Similar structure |
| D | Order Delete | 15 | Similar structure |
| U | Order Replace | 45 | Similar structure |

---

## File Structure

```
34-tcp-itch-parser/
├── README.md
├── src/
│   ├── tcp/
│   │   └── tcp_parser.vhd              # TCP segment parser
│   ├── transport/
│   │   ├── soupbintcp_handler.vhd      # SoupBinTCP session layer (ASX)
│   │   └── moldudp64_handler.vhd       # MoldUDP64 session layer (NASDAQ)
│   ├── itch/
│   │   ├── asx_itch_parser.vhd         # ASX ITCH message parser
│   │   ├── asx_itch_msg_pkg.vhd        # ASX message definitions
│   │   └── nasdaq/
│   │       └── nasdaq_itch_parser.vhd  # NASDAQ ITCH 5.0 parser
│   ├── sbe/                             # (planned) B3 SBE protocol
│   │   ├── sbe_header_decoder.vhd      # SBE message header parser
│   │   ├── sbe_group_iterator.vhd      # Repeating group traversal
│   │   ├── decimal64_decoder.vhd       # IEEE 754 Decimal64 to fixed-point
│   │   └── umdf_incremental_parser.vhd # B3 UMDF incremental message parser
│   ├── xgmii/
│   │   ├── mac_parser_xgmii.vhd        # 10GbE MAC/IP parser (word-based, wire-speed)
│   │   ├── itch_echo_tx.vhd            # ITCH echo TX (echoes parsed messages over XGMII)
│   │   ├── link_init_tx.vhd            # Link startup packets (announces FPGA on network)
│   │   ├── raw_udp_echo_tx.vhd         # Raw UDP echo for loopback testing
│   │   └── simple_udp_tx.vhd           # Test UDP packet generator
│   ├── aurora/
│   │   └── aurora_tx_wrapper.vhd       # Aurora TX to FPGA2
│   ├── common/
│   │   ├── protocol_demux.vhd          # UDP/TCP/multicast routing
│   │   ├── symbol_filter_pkg.vhd       # Symbol filtering
│   │   └── market_data_common_pkg.vhd  # Unified message format (all protocols)
│   ├── debug/
│   │   ├── gtx_debug_reporter.v        # UART status reporter (GTX + parser counters)
│   │   └── uart_tx_simple.v            # Simple UART TX (115200 baud)
│   └── integration/
│       ├── fpga1_network_top.vhd       # FPGA1 top module
│       └── itch_message_mux.vhd        # ITCH message multiplexer (NASDAQ + ASX)
├── test/
│   ├── tb_tcp_parser.vhd               # (planned)
│   ├── tb_soupbintcp_handler.vhd       # (planned)
│   ├── tb_asx_itch_parser.vhd          # (planned)
│   └── tb_sbe_decoder.vhd             # (planned) B3 SBE decode tests
├── scripts/
│   ├── run_build.tcl                   # Full build (with PHY)
│   ├── run_synth_test.tcl              # Synthesis-only test
│   └── files.f                         # File list for simulators
├── constraints/
│   ├── fpga1_network_pins.xdc          # Pin assignments
│   └── fpga1_network_timing.xdc        # Timing constraints
└── docs/
    ├── TCP_PARSER_DESIGN.md            # (planned)
    └── ASX_ITCH_DIFFERENCES.md         # (planned)
```

---

## Building

### Prerequisites
- Vivado 2025.1+
- ALINX AX7325B board with 10GbE SFP+
- Project 33 (10GBASE-R PHY) for full build

### Quick Syntax Check (No PHY dependency)
```bash
cd 34-tcp-itch-parser
vivado -mode batch -source scripts/run_synth_test.tcl
```

### Full Build (With 10GBASE-R PHY)
```bash
cd 34-tcp-itch-parser
vivado -mode batch -source scripts/run_build.tcl
```

### Build Outputs
- Bitstream: `vivado/fpga1_network_ingress.bit`
- Utilization report: `vivado/reports/utilization_impl.rpt`
- Timing report: `vivado/reports/timing_impl.rpt`

### LED Status Indicators
| LED | Signal | Meaning |
|-----|--------|---------|
| LED0 | QPLL Lock | GTX QPLL locked to reference clock |
| LED1 | GTX Ready | GTX transceiver initialized |
| LED2 | PCS Lock | 10GBASE-R block lock achieved (link up) |
| LED3 | Aurora Up | Aurora link to FPGA2 established |

---

## Resource Utilization (post-implementation, Feb 12 2026)

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| Slice LUTs | 2,008 | 203,800 | 0.99% |
| LUT as Logic | 1,940 | 203,800 | 0.95% |
| LUT as Distributed RAM | 64 | 64,000 | 0.10% |
| Slice Registers | 1,945 | 407,600 | 0.48% |
| BRAM Tiles | 1 | 445 | 0.22% |
| F7 Muxes | 47 | 101,900 | 0.05% |
| GTX Transceivers | 1 | 16 | 6.25% |
| BUFG | 4 | 32 | 12.50% |
| MMCM | 1 | 10 | 10.00% |

**Timing Summary:**
- sys_clk (200 MHz): WNS +1.994ns, 0 failing paths
- tx_mmcm_clk1 (161.13 MHz): WNS +0.922ns, 0 failing paths
- 0 TIMING-17 critical warnings, 0 unconstrained registers

---

## Current Hardware Status (2026-02-16)

### Full Pipeline Verified
All pipeline stages operational. Test with 1000 NASDAQ ITCH messages via 10GbE:

```
Q:1 L:0 T:1 R:1 BL:1 CD:1 EI:0 PR:0 ST:7 SD:F763 FC:F71D UC:0465 MC:0451 MX:027A NM:025E [OK]
```

- **UC:0x0465** (1125) - MAC parser extracting UDP payloads at wire speed
- **MC:0x0451** (1105) - MoldUDP64 packets parsed (session/sequence/count)
- **MX:0x027A** (634) - Individual ITCH messages extracted from MoldUDP64
- **NM:0x025E** (606) - NASDAQ ITCH messages fully parsed (type/fields extracted)

### Debug Reporter Fields
```
Q:1 L:0 T:1 R:1 BL:1 CD:1 EI:0 PR:0 ST:7 SD:XXXX FC:XXXX UC:XXXX MC:XXXX MX:XXXX NM:XXXX [OK]
```
| Field | Meaning | Expected |
|-------|---------|----------|
| Q | QPLL lock | 1 |
| L | REFCLK lost | 0 |
| T | TX reset done | 1 |
| R | RX reset done | 1 |
| BL | PCS block lock | 1 |
| CD | CDR lock (unreliable) | info only |
| EI | Electrical idle (unreliable) | info only |
| PR | PCS reset | 0 (critical) |
| ST | Block lock FSM state | 7 = LOCKED |
| SD | Start Detect (XGMII Start codes) | incrementing |
| FC | Frame Count (Start->Terminate) | incrementing |
| UC | UDP packet count | incrementing |
| MC | MoldUDP64 packet count | incrementing |
| MX | MoldUDP64 messages extracted | incrementing |
| NM | NASDAQ ITCH messages parsed | incrementing |

### Test Setup Hardware

Most developers will not have 10GbE networking at home (2.5GbE is common at best). This project was verified using a dedicated 10GbE fiber-optic test setup:

```
┌──────────────┐         ┌─────────────────────┐         ┌──────────────┐
│ PC           │  RJ45   │ 10GbE Managed       │  SFP+   │ AX7325B      │
│ (AQC107 NIC)│◄───────►│ Switch (Binardat)   │◄───────►│ FPGA Board   │
│ 10G RJ45    │  10Gb   │ 4xRJ45 + 4xSFP+    │  Fiber  │ (SFP+ Cage)  │
└──────────────┘         └─────────────────────┘         └──────────────┘
                                                    │
                                              OM3 LC-LC Fiber
                                              + 10G SFP+ Modules
```

**Hardware used:**

| Component | Product | Specs |
|-----------|---------|-------|
| SFP+ Modules | 10G SFP+ Fiber Transceiver | SR MM850nm, 300m range, Duplex LC |
| Fiber Cable | Tunghey OM3 LC to LC Patch Cable | Multimode Duplex 50/125um, 15M, LS-ZH |
| 10GbE Switch | Binardat 8-Port 10G Managed Switch | 4x10G RJ45 + 4x10G SFP+, 160Gbps, L3 |
| PC NIC | Binardat 10G PCIe Network Adapter | Aquantia AQC107 chip, RJ45, PXE support |

**Important notes:**
- DAC (Direct Attach Copper) cables did **not** work with the AX7325B SFP+ cage -- fiber optics required
- The switch bridges 10G RJ45 (PC side) to 10G SFP+ (FPGA side)
- SFP+ modules must be inserted into both the switch SFP+ port and the FPGA board SFP+ cage
- PC sends test packets via raw sockets or packet generator at 10Gbps line rate

---

## Component Status

| Component | Status | Notes |
|-----------|--------|-------|
| MAC/IP Parser (XGMII) | **Complete** | Word-based architecture, wire-speed 10GbE payload extraction |
| Simple UDP TX | **Complete** | Test packet generation, verified on Wireshark |
| ITCH Echo TX | **Complete** | Echoes parsed ITCH fields back over 10GbE for validation |
| Link Init TX | **Complete** | Announces FPGA presence on network at startup |
| Protocol Demux | **Complete** | UDP/TCP routing by protocol field |
| TCP Parser | **Complete** | Header parsing, flags, options handling |
| SoupBinTCP Handler | **Complete** | ASX session layer, sequenced data |
| MoldUDP64 Handler | **Complete** | NASDAQ session layer, gap detection |
| NASDAQ ITCH Parser | **Complete** | Add/Execute/Delete/Cancel/Replace |
| ASX ITCH Parser | **Complete** | Add/Execute/Delete/Cancel/Replace |
| Message Mux | **Complete** | NASDAQ + ASX arbitration |
| Aurora TX | **Complete** | 64B/66B encoding, FPGA2 interface |
| FPGA1 Integration | **Complete** | Full pipeline instantiation |
| GTX Debug Reporter | **Complete** | UART status with parser counters |
| Pin Constraints | **Complete** | AX7325B SFP+, Aurora, LEDs |
| Timing Constraints | **Complete** | MMCM clock CDC constraints |
| Build Scripts | **Complete** | Vivado TCL automation |
| Testbenches | Pending | Verification needed |

## Dependencies

### Project 33 (10GBASE-R PHY)
The following components from Project 33 are required for full FPGA1 build:

| Component | Purpose |
|-----------|---------|
| gtx_10g_wrapper.vhd | GTX transceiver configuration |
| pcs_10gbase_r.vhd | 64B/66B PCS layer |
| encoder_64b66b.vhd | TX encoding |
| decoder_64b66b.vhd | RX decoding |
| block_lock_fsm.vhd | Block synchronization |
| scrambler_tx.vhd | IEEE 802.3 scrambler |
| descrambler_rx.vhd | IEEE 802.3 descrambler |

---

## References

- IEEE 802.3-2018: Ethernet
- RFC 793: Transmission Control Protocol
- SoupBinTCP 3.0 Specification (Nasdaq)
- ASX Trade ITCH Message Specification v3.2
- NASDAQ TotalView-ITCH 5.0 Specification

---

## Related Projects

- **[23-order-book](https://github.com/adilsondias-engineer/23-order-book/)** - NASDAQ ITCH parser (UDP)
- **[33-10gbe-phy-custom](https://github.com/adilsondias-engineer/33-10gbe-phy-custom/)** - 10GbE PHY layer
- **[06-udp-parser-mii-v5](https://github.com/adilsondias-engineer/06-udp-parser-mii-v5/)** - UDP parser foundation

---

**Status:** Hardware Verified - WNS +0.922ns, 0 critical warnings, all clock domains constrained
**Created:** January 2026
**Last Updated:** February 16, 2026
**Author:** Adilson Dias
**Target Board:** ALINX AX7325B (Kintex-7 XC7K325T-2FFG900I)
