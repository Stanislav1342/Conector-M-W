package main

import (
	"bytes"
	"fmt"
	"image"
	"image/png"
)

func normalizeRect(x0, y0, x1, y1, maxW, maxH int) (left, top, right, bottom int) {
	if x0 > x1 {
		x0, x1 = x1, x0
	}
	if y0 > y1 {
		y0, y1 = y1, y0
	}
	if x0 < 0 {
		x0 = 0
	}
	if y0 < 0 {
		y0 = 0
	}
	if x1 > maxW {
		x1 = maxW
	}
	if y1 > maxH {
		y1 = maxH
	}
	return x0, y0, x1, y1
}

func encodeBGRACropToPNG(bgra []byte, imgW, imgH, x0, y0, x1, y1 int) ([]byte, error) {
	if imgW <= 0 || imgH <= 0 || len(bgra) < imgW*imgH*4 {
		return nil, fmt.Errorf("invalid source buffer")
	}
	l, t, r, b := normalizeRect(x0, y0, x1, y1, imgW, imgH)
	w := r - l
	h := b - t
	if w < 2 || h < 2 {
		return nil, fmt.Errorf("selection too small: %dx%d", w, h)
	}
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for row := 0; row < h; row++ {
		srcRow := (t + row) * imgW * 4
		dstRow := row * img.Stride
		for col := 0; col < w; col++ {
			s := srcRow + (l+col)*4
			d := dstRow + col*4
			img.Pix[d] = bgra[s+2]   // R
			img.Pix[d+1] = bgra[s+1] // G
			img.Pix[d+2] = bgra[s]   // B
			img.Pix[d+3] = 255       // A
		}
	}
	var out bytes.Buffer
	if err := png.Encode(&out, img); err != nil {
		return nil, err
	}
	if out.Len() > maxClipboardImageBytes {
		return nil, fmt.Errorf("screenshot too large (%d bytes)", out.Len())
	}
	return out.Bytes(), nil
}
