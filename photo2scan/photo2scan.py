#!/usr/bin/env python3
"""Turn phone photos of paper pages into a scanned-looking PDF.

For each photo: find the page's four corners, undo the camera angle,
even out the lighting, then put all pages into one PDF.
"""
import argparse
import sys

import cv2
import img2pdf
import numpy as np

DETECT_HEIGHT = 1000  # detect corners on a downscaled copy for speed


def order_corners(pts):
    """Return corners as top-left, top-right, bottom-right, bottom-left."""
    pts = pts.reshape(4, 2).astype(np.float32)
    s = pts.sum(axis=1)
    d = np.diff(pts, axis=1).ravel()
    return np.array([pts[np.argmin(s)], pts[np.argmin(d)],
                     pts[np.argmax(s)], pts[np.argmax(d)]], dtype=np.float32)


def quad_from_contour(contour):
    """Reduce a contour to four corners, loosening the fit until it works."""
    hull = cv2.convexHull(contour)
    peri = cv2.arcLength(hull, True)
    for eps in np.linspace(0.01, 0.1, 19):
        approx = cv2.approxPolyDP(hull, eps * peri, True)
        if len(approx) == 4:
            return approx
    # Fall back to the smallest rotated rectangle around the page.
    return cv2.boxPoints(cv2.minAreaRect(hull)).reshape(4, 1, 2)


def find_page(img):
    """Find the page's corners in full-resolution pixel coordinates."""
    scale = DETECT_HEIGHT / img.shape[0]
    small = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    area = small.shape[0] * small.shape[1]

    # Paper is bright and low in color; the background usually isn't.
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    sat, val = hsv[:, :, 1], hsv[:, :, 2]
    score = cv2.GaussianBlur(val.astype(np.int16) - sat.astype(np.int16), (0, 0), 3)
    score = np.clip(score, 0, 255).astype(np.uint8)
    _, mask = cv2.threshold(score, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)

    # Close gaps left by dark text and table lines inside the page.
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (15, 15))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)

    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return None, mask
    page = max(contours, key=cv2.contourArea)
    if cv2.contourArea(page) < 0.2 * area:
        return None, mask
    return order_corners(quad_from_contour(page)) / scale, mask


def straighten(img, corners):
    tl, tr, br, bl = corners
    width = int(max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl)))
    height = int(max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr)))
    target = np.array([[0, 0], [width - 1, 0], [width - 1, height - 1], [0, height - 1]],
                      dtype=np.float32)
    matrix = cv2.getPerspectiveTransform(corners, target)
    return cv2.warpPerspective(img, matrix, (width, height), flags=cv2.INTER_CUBIC)


def clean(img, mode):
    """Flatten uneven lighting so the paper comes out white."""
    if mode == "color":
        background = cv2.GaussianBlur(cv2.dilate(img, np.ones((7, 7), np.uint8)), (0, 0), 25)
        return cv2.divide(img, background, scale=255)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    background = cv2.GaussianBlur(cv2.dilate(gray, np.ones((7, 7), np.uint8)), (0, 0), 25)
    flat = cv2.divide(gray, background, scale=255)
    if mode == "bw":
        bw = cv2.adaptiveThreshold(flat, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                   cv2.THRESH_BINARY, 31, 15)
        # The adaptive threshold only keeps the edges of large dark areas
        # (filled header bars), so fill in anything much darker than the paper
        # around it. The paper's brightness is measured over a wide area, so
        # shadows across the page don't count as dark.
        h, w = gray.shape
        small = cv2.resize(gray, (200, max(1, round(200 * h / w))), interpolation=cv2.INTER_AREA)
        paper = cv2.resize(cv2.medianBlur(small, 21), (w, h), interpolation=cv2.INTER_LINEAR)
        bw[gray < paper.astype(np.float32) * 0.55] = 0
        return bw
    # Gray: stretch so faint pencil and the paper's gray cast separate.
    return cv2.normalize(np.clip(flat.astype(np.float32) * 1.15 - 30, 0, 255), None,
                         0, 255, cv2.NORM_MINMAX).astype(np.uint8)


def main():
    parser = argparse.ArgumentParser(prog="photo2scan", description=__doc__)
    parser.add_argument("photos", nargs="+", help="photos, one page each, in page order")
    parser.add_argument("-o", "--output", required=True, help="PDF to write")
    parser.add_argument("-m", "--mode", choices=["gray", "bw", "color"], default="gray",
                        help="gray (default), bw for black and white, or color")
    parser.add_argument("--debug", action="store_true",
                        help="also save each photo with the detected page outlined")
    args = parser.parse_args()

    letter = (img2pdf.in_to_pt(8.5), img2pdf.in_to_pt(11))
    layout = img2pdf.get_layout_fun(letter, fit=img2pdf.FitMode.into)

    pages = []
    for path in args.photos:
        img = cv2.imread(path)  # applies the photo's EXIF rotation
        if img is None:
            sys.exit(f"{path}: could not read image")
        corners, mask = find_page(img)
        if corners is None:
            print(f"{path}: no page found, using the whole photo", file=sys.stderr)
            page = img
        else:
            page = straighten(img, corners)
        if args.debug:
            outline = img.copy()
            if corners is not None:
                cv2.polylines(outline, [corners.astype(np.int32)], True, (0, 0, 255), 12)
            cv2.imwrite(f"{path}.detected.jpg", outline)
        ok, png = cv2.imencode(".png", clean(page, args.mode))
        pages.append(png.tobytes())

    with open(args.output, "wb") as f:
        f.write(img2pdf.convert(pages, layout_fun=layout))
    print(f"wrote {args.output} ({len(pages)} page{'s' if len(pages) != 1 else ''})")


if __name__ == "__main__":
    main()
