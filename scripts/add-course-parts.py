"""Install the course board parts into a fritzing-parts tree, before parts.db is generated.

Every part from parts/dist/*.fzpz becomes contrib/<moduleId>.fzp plus its SVGs under svg/contrib/<view>/,
and a "Kurs IoT" bin in bins/more/ lists them; BinManager::findAllBins opens every bins/more/*.fzb as a
tab. Only new, untracked files are added: the parts updater (git reset --hard / checkout) restores
tracked files but leaves untracked ones in place, so the course parts survive "Check for parts updates".

usage: add-course-parts.py <fritzing-parts dir>
"""
import shutil
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

KIT = Path(__file__).resolve().parent.parent
BIN_NAME = "kurs-iot"
BIN_TITLE = "Kurs IoT"


def place(target: Path, data: bytes) -> None:
    # Never replace an upstream file: a name clash means the moduleId has to change.
    if target.exists() and target.read_bytes() != data:
        sys.exit(f"refusing to overwrite {target}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


def install(parts: Path, fzpz: Path) -> tuple[str, str, str]:
    with zipfile.ZipFile(fzpz) as archive:
        names = archive.namelist()
        fzp_names = [n for n in names if n.endswith(".fzp")]
        if len(fzp_names) != 1:
            sys.exit(f"{fzpz.name}: expected one .fzp, found {fzp_names}")
        fzp = archive.read(fzp_names[0])
        module = ET.fromstring(fzp)
        module_id = module.get("moduleId")
        title = module.findtext("title")
        for layers in module.iter("layers"):
            image = layers.get("image")  # e.g. breadboard/course64-abx00083.svg
            view, svg_name = image.split("/")
            # Inside a .fzpz the SVG is stored as svg.<view>.<file name>.
            place(parts / "svg" / "contrib" / view / svg_name, archive.read(f"svg.{view}.{svg_name}"))
        fzp_file = f"{module_id}.fzp"
        place(parts / "contrib" / fzp_file, fzp)
    return module_id, fzp_file, title


def instance(module_id: str, path: str, extra: str = "") -> str:
    return (f'\t\t<instance moduleIdRef="{module_id}"{extra} path="{path}">\n'
            '\t\t\t<views>\n\t\t\t\t<iconView layer="icon">\n'
            '\t\t\t\t\t<geometry z="-1" x="-1" y="-1"></geometry>\n'
            '\t\t\t\t</iconView>\n\t\t\t</views>\n\t\t</instance>\n')


def main() -> None:
    # Part titles contain non-ASCII characters; a cp1252 console must not abort the build.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parts = Path(sys.argv[1])
    if not (parts / "bins" / "core.fzb").is_file():
        sys.exit(f"{parts} is not a fritzing-parts tree")
    installed = [install(parts, f) for f in sorted((KIT / "parts" / "dist").glob("*.fzpz"))]
    if not installed:
        sys.exit("no .fzpz files in parts/dist")

    body = instance("__spacer__", "Płytki kursu", ' modelIndex="1"')
    body += "".join(instance(module_id, fzp_file) for module_id, fzp_file, _ in installed)
    fzb = ('<?xml version="1.0" encoding="UTF-8"?>\n'
           f'<module fritzingVersion="1.0.8" icon="{BIN_NAME}.png">\n'
           f'\t<title>{BIN_TITLE}</title>\n\t<instances>\n{body}\t</instances>\n</module>\n')
    more = parts / "bins" / "more"
    place(more / f"{BIN_NAME}.fzb", fzb.encode("utf-8"))
    for icon in (f"{BIN_NAME}.png", f"{BIN_NAME}-mono.png"):
        shutil.copyfile(KIT / "parts" / "bin" / icon, more / icon)
    for module_id, fzp_file, title in installed:
        print(f"installed {module_id} ({title}) as contrib/{fzp_file}")
    print(f"bin {BIN_TITLE!r}: bins/more/{BIN_NAME}.fzb")


if __name__ == "__main__":
    main()
