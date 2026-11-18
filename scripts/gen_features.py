"""Golden model for the Stage 3b feature extractor (feature_stream + conv_layer).

Uses the same 96x64 test image as the Sobel stages (image.hex) and two banks of
4 filters each. Each input pixel carries a bank bit, and a window uses the bank
of its newest (bottom-right) pixel. bank_of() decides it:
  - rows SWITCH_ROW and below: bank B (a switch in the middle of the frame);
  - rows BOX_ROWS, columns BOX_COL and right: also bank B, so the weights
    switch in the middle of a row and back again at every row end. That gives
    the testbench many switch points, not just one.

Writes:
  weights.hex            72 lines: bank A filters 0-3 (9 taps each), then bank B.
                         Tap 0 = top-left ... tap 8 = bottom-right. Signed int8, hex.
  features_expected.txt  one line per output pixel: f0 f1 f2 f3 (32-bit two's-complement hex)

Run:  python gen_features.py      (from this folder; needs gen_sobel.py, png_util.py)
"""
from gen_sobel import make_image, IMG_W, IMG_H

SWITCH_ROW = 32           # these three must match tb_feature_stream.v
BOX_ROWS = range(8, 16)
BOX_COL = 48


def bank_of(row, col):
    """Bank bit of input pixel (row, col): 0 = A, 1 = B."""
    return 1 if row >= SWITCH_ROW or (row in BOX_ROWS and col >= BOX_COL) else 0

BANK_A = [
    ("Sobel Gx",   [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]),
    ("Sobel Gy",   [[-1, -2, -1], [0, 0, 0], [1, 2, 1]]),
    ("Laplacian",  [[0, 1, 0], [1, -4, 1], [0, 1, 0]]),
    ("Gaussian",   [[1, 2, 1], [2, 4, 2], [1, 2, 1]]),
]
BANK_B = [
    ("Diagonal",   [[0, 1, 2], [-1, 0, 1], [-2, -1, 0]]),
    ("Emboss",     [[-2, -1, 0], [-1, 1, 1], [0, 1, 2]]),
    ("Sharpen",    [[0, -1, 0], [-1, 5, -1], [0, -1, 0]]),
    ("Extremes",   [[127, -128, 127], [-128, 127, -128], [127, -128, 127]]),
]


def flat(k):
    return [k[r][c] for r in range(3) for c in range(3)]


def features(img):
    out = []
    for y in range(1, IMG_H - 1):              # window centre
        for x in range(1, IMG_W - 1):
            bank = BANK_B if bank_of(y + 1, x + 1) else BANK_A   # newest pixel is (y+1, x+1)
            win = [img[y - 1 + r][x - 1 + c] for r in range(3) for c in range(3)]
            out.append([sum(p * w for p, w in zip(win, flat(k))) for _, k in bank])
    return out


if __name__ == "__main__":
    img = make_image()
    res = features(img)
    with open("weights.hex", "w") as f:
        for _, k in BANK_A + BANK_B:
            for w in flat(k):
                f.write("%02x\n" % (w & 0xFF))
    with open("features_expected.txt", "w") as f:
        for r in res:
            f.write(" ".join("%08x" % (v & 0xFFFFFFFF) for v in r) + "\n")
    print("Wrote weights.hex (72 weights) and features_expected.txt (%d outputs x 4 filters)" % len(res))
