#!/usr/bin/env python3
"""Build the offline country outlines using Python's standard library only."""

import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson/ne_50m_admin_0_countries.geojson"
SOURCE_SHA256 = "3e458fc036ad0a66411f2c1e6cac49c5d7bfb81cb1123bc513b22511a2b7fdeb"
TOLERANCE = 0.02  # Degrees, maximum perpendicular error before coordinate rounding.


def area(ring):
    return sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(ring, ring[1:])) / 2


def distance_squared(point, start, end):
    dx, dy = end[0] - start[0], end[1] - start[1]
    length = dx * dx + dy * dy
    t = max(0, min(1, ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / length)) if length else 0
    return (point[0] - start[0] - t * dx) ** 2 + (point[1] - start[1] - t * dy) ** 2


def simplify_arc(points):
    """RDP with canonical direction: neighbours get exactly the same border."""
    reverse = points[0] > points[-1]
    points = points[::-1] if reverse else points
    keep = {0, len(points) - 1}
    pending = [(0, len(points) - 1)]
    while pending:
        first, last = pending.pop()
        if last - first < 2:
            continue
        furthest = max(range(first + 1, last), key=lambda i: distance_squared(points[i], points[first], points[last]))
        if distance_squared(points[furthest], points[first], points[last]) > TOLERANCE ** 2:
            keep.add(furthest)
            pending.extend(((first, furthest), (furthest, last)))
    result = [points[i] for i in sorted(keep)]
    return result[::-1] if reverse else result


def simplify_ring(ring, protected):
    points = ring[:-1]
    cuts = [i for i, point in enumerate(points) if point in protected]
    # The global protected set contains every ring's extrema, including small
    # islands; no ring may collapse to a line or be omitted for its size.
    assert len(cuts) >= 2
    result = []
    for index, first in enumerate(cuts):
        last = cuts[(index + 1) % len(cuts)]
        arc = points[first:last + 1] if last > first else points[first:] + points[:last + 1]
        result.extend(simplify_arc(arc)[:-1])
    return result + [result[0]]


def has_crossing(ring):
    """Detect new proper self-intersections with a small bounding-box sweep."""
    segments = []
    for index, (a, b) in enumerate(zip(ring, ring[1:])):
        segments.append((min(a[0], b[0]), max(a[0], b[0]), min(a[1], b[1]), max(a[1], b[1]), index, a, b))
    active = []
    def side(a, b, c):
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    for segment in sorted(segments):
        x0, x1, y0, y1, index, a, b = segment
        active = [other for other in active if other[1] >= x0]
        for other in active:
            if abs(index - other[4]) in (1, len(segments) - 1) or y1 < other[2] or y0 > other[3]:
                continue
            c, d = other[5:]
            if side(a, b, c) * side(a, b, d) < 0 and side(c, d, a) * side(c, d, b) < 0:
                return True
        active.append(segment)
    return False


def rounded_ring(ring):
    for digits in (3, 6):
        result = []
        for point in ring:
            rounded = tuple(round(coordinate, digits) for coordinate in point)
            if not result or rounded != result[-1]:
                result.append(rounded)
        if result[-1] != result[0]:
            result.append(result[0])
        if len(set(result[:-1])) >= 3 and area(result) * area(ring) > 0 and not has_crossing(result):
            return result
    return ring


def generate(source):
    features = [feature for feature in source["features"] if feature["properties"]["ISO_A2_EH"] != "AQ"]
    legacy = json.loads((ROOT / "scripts/map-country-anchors.json").read_text())
    anchors = {entry["id"]: entry for entry in legacy}
    assert set(anchors) <= {feature["properties"]["ADM0_A3"] for feature in features}, "Legacy country missing"
    order = {entry["id"]: index for index, entry in enumerate(legacy)}
    features.sort(key=lambda feature: (order.get(feature["properties"]["ADM0_A3"], len(order)), feature["properties"]["ADM0_A3"]))
    neighbours = defaultdict(set)
    protected = set()
    countries = []
    for feature in features:
        properties = feature["properties"]
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        rings = [list(map(tuple, polygon[0])) for polygon in polygons]
        code = properties["ISO_A2_EH"]
        country = {"i": "" if code == "-99" else code,
                   "a": [round(properties["LABEL_X"], 2), round(properties["LABEL_Y"], 2)], "r": rings}
        if properties["ADM0_A3"] in anchors:
            anchor = anchors[properties["ADM0_A3"]]
            assert country["i"] == anchor["i"], "Legacy ISO code changed"
            country["a"] = anchor["a"]
        countries.append(country)
        for ring in rings:
            assert ring[0] == ring[-1] and len(set(ring[:-1])) >= 3
            for dimension in (0, 1):
                protected.add(min(ring, key=lambda point: (point[dimension], point)))
                protected.add(max(ring, key=lambda point: (point[dimension], point)))
            for a, b in zip(ring, ring[1:]):
                neighbours[a].add(b)
                neighbours[b].add(a)
    # Split at coastline/border junctions. Shared arcs then simplify together,
    # instead of independently pulling neighbouring country borders apart.
    protected.update(point for point, adjacent in neighbours.items() if len(adjacent) != 2)
    rings = [ring for country in countries for ring in country["r"]]
    while True:
        simplified = [simplify_ring(ring, protected) for ring in rings]
        rejected = [original for original, result in zip(rings, simplified)
                    if result != original and (len(set(result[:-1])) < 3 or area(original) * area(result) <= 0
                    or abs(area(result) / area(original) - 1) > 0.02 or has_crossing(result))]
        additions = {point for ring in rejected for point in ring} - protected
        if not additions:
            break
        # Keep the complete source outline for narrow/tiny/problematic rings,
        # and propagate its preserved vertices to adjoining country borders.
        protected.update(additions)
    output_rings = iter(rounded_ring(ring) for ring in simplified)
    for country in countries:
        country["r"] = [next(output_rings) for _ in country["r"]]
    assert len(countries) == len(features) and len(rings) == sum(len(country["r"]) for country in countries)
    assert all(-180 <= lon <= 180 and -90 <= lat <= 90 for country in countries for ring in country["r"] for lon, lat in ring)
    assert all(country["i"] != "AQ" for country in countries)
    return {"c": countries}, len(rings), sum(map(len, rings))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Use a downloaded source GeoJSON instead of fetching it")
    parser.add_argument("--output", type=Path, default=ROOT / "app/assets/map/countries.json")
    args = parser.parse_args()
    data = args.source.read_bytes() if args.source else urllib.request.urlopen(SOURCE, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise SystemExit("Source checksum mismatch; refusing to silently change map data")
    result, ring_count, source_points = generate(json.loads(data))
    payload = json.dumps(result, separators=(",", ":"), ensure_ascii=True) + "\n"
    args.output.write_text(payload)
    points = sum(len(ring) for country in result["c"] for ring in country["r"])
    print(f"{len(result['c'])} countries/territories, {ring_count} exterior rings, {source_points} -> {points} points, {len(payload.encode())} bytes")


if __name__ == "__main__":
    main()
