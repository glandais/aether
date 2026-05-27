#!/usr/bin/env python3
"""Génère `Aether/Resources/bsc5.bin` depuis le Yale Bright Star Catalog (BSC5).

Source : Yale Bright Star Catalog, 5e édition révisée (Hoffleit & Warren, 1991),
distribué par le Astronomical Data Center / Harvard
(http://tdc-www.harvard.edu/catalogs/bsc5.html). ~9110 enregistrements à
largeur fixe ; on n'en retient que la position J2000, la magnitude visuelle et
l'indice de couleur B-V.

Format de sortie (little-endian, 16 octets par étoile) :
    float32 ra_rad   — ascension droite J2000 (radians)
    float32 dec_rad  — déclinaison J2000 (radians)
    float32 vmag     — magnitude visuelle apparente
    float32 bv       — indice de couleur B-V (0 si absent → blanc neutre)

Les entrées sans position (objets supprimés / non stellaires) sont ignorées.

Usage :
    curl -sL http://tdc-www.harvard.edu/catalogs/bsc5.dat.gz | gunzip > bsc5.dat
    python3 scripts/build_star_catalog.py bsc5.dat Aether/Resources/bsc5.bin
"""

import math
import struct
import sys


def field(line: str, start: int, end: int) -> str:
    """Sous-chaîne en octets 1-indexés inclusifs (convention ReadMe ADC)."""
    return line[start - 1:end]


def parse(line: str):
    """(ra_rad, dec_rad, vmag, bv) ou None si l'entrée n'a pas de position."""
    rah, ram, ras = field(line, 76, 77), field(line, 78, 79), field(line, 80, 83)
    if not rah.strip() or not ram.strip() or not ras.strip():
        return None  # objet supprimé / sans position

    ra_hours = int(rah) + int(ram) / 60.0 + float(ras) / 3600.0
    ra_rad = math.radians(ra_hours * 15.0)  # 15°/heure

    sign = -1.0 if field(line, 84, 84) == "-" else 1.0
    ded, dem, des = field(line, 85, 86), field(line, 87, 88), field(line, 89, 90)
    dec_deg = sign * (int(ded) + int(dem) / 60.0 + int(des) / 3600.0)
    dec_rad = math.radians(dec_deg)

    vmag = float(field(line, 103, 107))
    bv_raw = field(line, 110, 114).strip()
    bv = float(bv_raw) if bv_raw else 0.0

    return ra_rad, dec_rad, vmag, bv


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(f"usage: {sys.argv[0]} <bsc5.dat> <bsc5.bin>")
    src, dst = sys.argv[1], sys.argv[2]

    count = 0
    with open(src, "r", encoding="latin-1") as f, open(dst, "wb") as out:
        for line in f:
            parsed = parse(line.rstrip("\n"))
            if parsed is None:
                continue
            out.write(struct.pack("<ffff", *parsed))
            count += 1

    print(f"{count} étoiles écrites dans {dst} ({count * 16} octets)")


if __name__ == "__main__":
    main()
