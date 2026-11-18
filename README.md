# FPGA Accelerator, Stage 3: systolic convolution engines

Stage 3 of a small image-processing accelerator in Verilog on a Xilinx Virtex-6 (ML605 board,
XC6VLX240T). It turns the programmable 3x3 convolution engine from Stage 2 into a **systolic
array**, the structure used by TPU-style neural-network accelerators, and then builds toward a
small convolution layer.

Stages 1–2 (the MAC unit and the five Sobel edge-detector versions this work starts from) are in
[fpga-accelerator-stage2](https://github.com/solistolen/fpga-accelerator-stage2).

![Input, golden model, hardware output](results/images/comparison.png)

*Left: 96x64 test image. Middle: edges from the Python golden model. Right: edges produced by the
Stage 3a Verilog in simulation. All 5,828 output pixels match.*

## Stage 3a: systolic 3x3 engine

In Stage 2d the slowest path was one hop between two DSP48E1s: one DSP added its product to the
partial sum and passed the result on **unregistered**, so the next DSP did a second add in the same
clock (3.70 ns). `conv3x3_sys` is a systolic chain: every tap stores its partial sum in its DSP's
P register, and the next tap adds to it on the next clock.

```
tap 0:  P0 <= x0*w0
tap 1:  P1 <= P0 + x1*w1        (P0 from the previous clock)
...
tap 8:  P8 <= P7 + x8*w8        = finished sum
```

The partial sum reaches tap *i* exactly *i* clocks after tap 0, so pixel *i* is delayed by *i*
clocks too (the "skew" delay line in each tap). Latency is 11 clocks; throughput is still one
3x3 window per clock, and the engine is still **programmable** (coefficients on a port).

### Results

XST synthesis estimates (ISE 14.7, xc6vlx240t-1-ff1156, `IMG_W = 640`), before place-and-route,
compared with the Stage 2 designs it replaces:

| | 2d (programmable) | 2e (fixed Sobel) | **3a (programmable, systolic)** |
|---|---|---|---|
| DSP48E1s | 18 | 0 | 18 |
| Block RAM (RAMB18) | 1 | 1 | 1 |
| Slice LUTs (incl. SRLs) | 255 | 227 | 239 (86 SRLs) |
| Slice registers | 206 | 248 | 278 |
| Slowest path | DSP→DSP hop (two adds) | BRAM read → write | magnitude add/clamp (fabric) |
| Period | 3.70 ns | 2.74 ns | 3.05 ns |
| **Est. clock** | **270 MHz** | **365 MHz** | **328 MHz** |
| Latency (clocks) | 7 | 6 | 15 |

- Every DSP runs with its multiplier and output registers on (XST: "registers also absorbed by the
  MAC: `m_r`, `pout`"), and the slowest path is no longer anywhere in the DSP chain. The
  programmable engine is within ~10% of the fixed Sobel's clock.
- Gx and Gy delay the same pixels, so XST merged their skew delay lines: the whole skew costs
  48 SRLs.
- Coefficients must only change while the engine is idle (each tap samples its coefficient at a
  different time). Stage 3b loads weights properly.

Report excerpt with the critical path: [`results/synthesis/3a_systolic_xst.txt`](results/synthesis/3a_systolic_xst.txt).

### Verification

Both testbenches pass in ISim 14.7 and Icarus Verilog 12:

- `tb_conv_sys` (unit test, no data files): `PASS: 7500 windows matched the reference (latency 11)`.
  25 coefficient sets (both Sobel kernels, all −128, all +127, a different value in every tap,
  and 20 random sets) × 300 random windows, with ~25% idle clocks.
- `tb_sobel` (full streaming Sobel against the Python golden model):
  `PASS: 5828 edge pixels matched the golden model`.

Planted bugs, to check the testbenches catch real mistakes:

| Bug | tb_conv_sys | tb_sobel |
|---|---|---|
| No skew (all delays 0) | FAIL | FAIL |
| Tap 4's delay off by one | FAIL | *passes*: tap 4 is the centre pixel, coefficient 0 in both Sobel kernels |
| Pixel sign-extended instead of zero-extended | FAIL | FAIL |
| Coefficient register unsigned | FAIL | FAIL |
| Valid-flag latency 10 instead of 11 | | FAIL |
| 10-clock drain at the end of tb_sobel | | FAIL (outputs missing) |

The tap-4 row is why the unit test uses a different coefficient in every tap.

## Repository layout

```
rtl/
  3a_systolic/      conv3x3_sys.v   systolic engine: conv3x3_sys (9 taps) + sys_tap
                    sobel.v         streaming Sobel: line buffer, 3x3 window, 2 x conv3x3_sys, magnitude
sim/
  tb_conv_sys.v                     unit testbench for conv3x3_sys (no data files)
  tb_sobel.v, image.hex, expected.txt   Sobel testbench + test image + golden results
scripts/
  gen_sobel.py      test image + golden Sobel model, writes image.hex / expected.txt
  show_result.py    turns the simulator's sim_out.hex into a PNG
  png_util.py       tiny PNG writer (no dependencies)
results/
  synthesis/        XST report excerpt
  images/           input, expected and hardware edge images
  sim_out_3a.hex    raw output of the Stage 3a Sobel simulation
```

## Running it

### Xilinx ISE 14.7 / ISim

1. New project: Virtex-6, xc6vlx240t, ff1156, speed -1, XST, ISim, Verilog.
2. Add `rtl/3a_systolic/*.v` (association **All**) and `sim/tb_conv_sys.v`, `sim/tb_sobel.v`
   (association **Simulation**). Copy `sim/image.hex` and `sim/expected.txt` into the project
   folder; they don't need to be added to the project.
3. Simulation view → `tb_conv_sys`, then `tb_sobel` → Simulate Behavioral Model → `run all`.
4. Implementation view → top = `sobel` → Synthesize - XST.

### Icarus Verilog (no Xilinx tools needed)

From the `sim/` folder:

```
iverilog -o conv_sim tb_conv_sys.v ../rtl/3a_systolic/conv3x3_sys.v
vvp conv_sim
iverilog -o sobel_sim tb_sobel.v ../rtl/3a_systolic/sobel.v ../rtl/3a_systolic/conv3x3_sys.v
vvp sobel_sim
python ../scripts/show_result.py    # sim_out.hex -> hardware.png
```

## Next

- **3b**: a conv-layer grid: several filters share one window, with weights loaded at runtime.
- **3c**: CNN-style output stage: bias, ReLU and requantization back to 8 bits.
