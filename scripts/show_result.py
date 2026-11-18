"""Turn the simulator's output (sim_out.hex) into a picture: hardware.png.

Copy sim_out.hex from the ISE project folder next to this script, then run:
    python show_result.py
Open hardware.png and compare it with expected.png.
"""
from png_util import write_png

IMG_W, IMG_H = 96, 64            # must match the testbench
W, H = IMG_W - 2, IMG_H - 2

vals = []
with open("sim_out.hex") as f:
    for line in f:
        line = line.strip()
        if line:
            vals.append(int(line, 16))

if len(vals) != W * H:
    print("Warning: got %d values, expected %d" % (len(vals), W * H))
    vals = (vals + [0] * (W * H))[:W * H]

write_png("hardware.png", [vals[r * W:(r + 1) * W] for r in range(H)], scale=4)
print("Wrote hardware.png (%d x %d edge image)" % (W, H))
