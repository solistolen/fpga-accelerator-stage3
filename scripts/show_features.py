"""Turn the simulator's sim_features.hex into a picture of the 4 feature maps.

Each panel is one filter. Pixels whose window used bank A show filter f of
bank A; the others (the bottom part and a box at the top right, see bank_of()
in gen_features.py) show filter f of bank B. Values are shown as |value|,
scaled separately per bank so the brightest pixel of each is white.

Run (in a folder with sim_features.hex, gen_features.py, gen_sobel.py,
png_util.py):  python show_features.py
Writes features.png.
"""
from png_util import write_png
from gen_features import bank_of

W, H, N_F, SUM_W = 94, 62, 4, 20


def s20(h):
    v = int(h, 16)
    return v - (1 << SUM_W) if v & (1 << (SUM_W - 1)) else v


vals = []
with open("sim_features.hex") as f:
    for line in f:
        if line.strip():
            vals.append([s20(x) for x in line.split()])
if len(vals) != W * H:
    print("Warning: got %d outputs, expected %d" % (len(vals), W * H))
    vals = (vals + [[0] * N_F] * (W * H))[:W * H]

# output (r, c) is the window whose newest pixel is input (r + 2, c + 2)
bank = [[bank_of(r + 2, c + 2) for c in range(W)] for r in range(H)]

panels = []
for flt in range(N_F):
    mag = [[abs(vals[r * W + c][flt]) for c in range(W)] for r in range(H)]
    peak = [max([mag[r][c] for r in range(H) for c in range(W) if bank[r][c] == b] or [1]) or 1
            for b in (0, 1)]
    panels.append([[min(255, mag[r][c] * 255 // peak[bank[r][c]]) for c in range(W)] for r in range(H)])

rows = []
for r in range(H):
    row = []
    for flt in range(N_F):
        row += panels[flt][r] + ([128] * 4 if flt < N_F - 1 else [])
    rows.append(row)
write_png("features.png", rows, scale=4)
print("Wrote features.png (4 feature maps, bank A and bank B regions scaled separately)")
