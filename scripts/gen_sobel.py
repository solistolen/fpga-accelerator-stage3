"""Golden model + test-image generator for the Stage 2b Sobel engine.

Makes a small grayscale test image and computes the exact Sobel results the
hardware must produce. Pure Python (no numpy/PIL needed); works on Python 2 or 3.

Writes:
  image.hex       one input pixel per line (hex), raster order
  expected.txt    one line per output: gx gy mag  (32-bit two's-complement hex)
  input.png       the test image, enlarged 4x so you can see it
  expected.png    the edge image the hardware should produce, enlarged 4x

Run:  python gen_sobel.py
"""
import random
from png_util import write_png

IMG_W, IMG_H = 96, 64            # must match the testbench parameters

KX = [[-1, 0, 1], [-2, 0, 2], [-1, 0, 1]]
KY = [[-1, -2, -1], [0, 0, 0], [1, 2, 1]]


def make_image():
    random.seed(13)
    img = [[0] * IMG_W for _ in range(IMG_H)]
    for y in range(IMG_H):
        for x in range(IMG_W):
            v = 40 + (x * 60) // IMG_W                       # soft left-to-right gradient
            if 10 <= x < 40 and 12 <= y < 44:                # bright rectangle
                v = 220
            if (x - 68) ** 2 + (y - 30) ** 2 < 15 ** 2:      # dark circle
                v = 15
            if y > 50 and (x // 8) % 2 == 0:                 # stripes along the bottom
                v = 180
            v += random.randint(-6, 6)                       # a little sensor noise
            img[y][x] = max(0, min(255, v))
    return img


def sobel(img):
    out = []
    for y in range(1, IMG_H - 1):           # only pixels with a full 3x3 neighbourhood
        for x in range(1, IMG_W - 1):
            gx = gy = 0
            for j in range(3):
                for i in range(3):
                    p = img[y - 1 + j][x - 1 + i]
                    gx += KX[j][i] * p
                    gy += KY[j][i] * p
            mag = min(255, abs(gx) + abs(gy))
            out.append((gx, gy, mag))
    return out


def h32(v):
    return "%08x" % (v & 0xFFFFFFFF)


if __name__ == "__main__":
    img = make_image()
    res = sobel(img)

    with open("image.hex", "w") as f:
        for row in img:
            for p in row:
                f.write("%02x\n" % p)

    with open("expected.txt", "w") as f:
        for gx, gy, mag in res:
            f.write("%s %s %s\n" % (h32(gx), h32(gy), h32(mag)))

    write_png("input.png", img, scale=4)
    mags = [r[2] for r in res]
    w = IMG_W - 2
    write_png("expected.png", [mags[i * w:(i + 1) * w] for i in range(IMG_H - 2)], scale=4)

    print("Wrote image.hex (%d pixels) and expected.txt (%d results)" % (IMG_W * IMG_H, len(res)))
