"""Turn the simulator's sim_cnn.hex into a picture of the 4 output feature maps.

These are the layer's real 8-bit outputs (after bias, ReLU and requantization),
drawn as they are, with no extra scaling: 0 = black, 255 = white.

Run (in a folder with sim_cnn.hex and png_util.py):  python show_cnn.py
Writes cnn.png.
"""
from png_util import write_png

W, H, N_F = 94, 62, 4

vals = []
with open("sim_cnn.hex") as f:
    for line in f:
        if line.strip():
            vals.append([int(x, 16) for x in line.split()])
if len(vals) != W * H:
    print("Warning: got %d outputs, expected %d" % (len(vals), W * H))
    vals = (vals + [[0] * N_F] * (W * H))[:W * H]

rows = []
for r in range(H):
    row = []
    for flt in range(N_F):
        row += [vals[r * W + c][flt] for c in range(W)] + ([128] * 4 if flt < N_F - 1 else [])
    rows.append(row)
write_png("cnn.png", rows, scale=4)
print("Wrote cnn.png (4 output feature maps, 8-bit, unscaled)")
