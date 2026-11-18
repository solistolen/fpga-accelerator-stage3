"""Golden model for the Stage 3c CNN layer (cnn_stream = conv_layer + requant).

Same test image, kernels and bank pattern as Stage 3b (imported from
gen_features.py), followed by the requant step for each filter:

    q = min(255, round_half_up(max(sum + bias, 0) * mult / 2^shift))

The parameters below were picked so each feature map uses most of 0..255, and
together they cover shift = 0, a large shift (24), mult = 65535, and negative
and positive biases.

Writes:
  quant.hex         8 lines, bank A filters 0-3 then bank B: "bias mult shift" in hex
                    (bias as 20-bit two's complement)
  cnn_expected.txt  one line per output pixel: q0 q1 q2 q3 (2 hex digits each)

Run:  python gen_cnn.py      (needs gen_features.py, gen_sobel.py, png_util.py)
"""
from gen_sobel import make_image
from gen_features import BANK_A, BANK_B, features

#           (name,        bias, mult,  shift)   scale = mult / 2^shift
QUANT_A = [("Sobel Gx",    -20, 24576, 16),     # 0.375; bias hides weak edges
           ("Sobel Gy",    -20, 24576, 16),
           ("Laplacian",     0, 49152, 15),     # 1.5
           ("Gaussian",      0,  4096, 16)]     # 1/16: the kernel sums to 16, so this is a plain blur
QUANT_B = [("Diagonal",    -10, 16384, 15),     # 0.5
           ("Emboss",      256, 32768, 17),     # 0.25, offset so flat areas are mid-grey
           ("Sharpen",       0,     1,  0),     # scale 1, shift 0: no rounding, lots of saturation
           ("Extremes",      0, 65535, 24)]     # ~0.0039, the largest mult and a big shift

SUM_W = 20


def requant(s, bias, mult, shift):
    r = max(s + bias, 0)
    p = r * mult
    if shift:
        p += 1 << (shift - 1)
    return min(p >> shift, 255)


def cnn(img):
    from gen_features import bank_of, IMG_W, IMG_H
    feats = features(img)
    out = []
    i = 0
    for y in range(1, IMG_H - 1):
        for x in range(1, IMG_W - 1):
            params = QUANT_B if bank_of(y + 1, x + 1) else QUANT_A
            out.append([requant(s, b, m, h) for s, (_, b, m, h) in zip(feats[i], params)])
            i += 1
    return out


if __name__ == "__main__":
    for (ka, _), (kb, _), (qa, *_), (qb, *_) in zip(BANK_A, BANK_B, QUANT_A, QUANT_B):
        assert ka == qa and kb == qb, "QUANT_A/B must list filters in the same order as BANK_A/B"
    res = cnn(make_image())
    with open("quant.hex", "w") as f:
        for _, b, m, h in QUANT_A + QUANT_B:
            f.write("%05x %04x %02x\n" % (b & ((1 << SUM_W) - 1), m, h))
    with open("cnn_expected.txt", "w") as f:
        for r in res:
            f.write(" ".join("%02x" % v for v in r) + "\n")
    print("Wrote quant.hex and cnn_expected.txt (%d outputs x 4 filters)" % len(res))
    for k in range(4):
        col = [r[k] for r in res]
        print("  filter %d: zeros %4d, mid %4d, 255s %4d, mean %5.1f"
              % (k, col.count(0), sum(1 for v in col if 0 < v < 255), col.count(255), sum(col) / len(col)))
