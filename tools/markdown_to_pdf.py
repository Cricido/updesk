import re
import sys
import textwrap
from pathlib import Path


PAGE_WIDTH = 595
PAGE_HEIGHT = 842
MARGIN_X = 54
MARGIN_TOP = 60
MARGIN_BOTTOM = 54
BODY_FONT_SIZE = 11
LINE_HEIGHT = 15
MAX_TEXT_WIDTH = PAGE_WIDTH - (MARGIN_X * 2)


def pdf_escape(text: str) -> str:
    return (
        text.replace("\\", "\\\\")
        .replace("(", "\\(")
        .replace(")", "\\)")
    )


def sanitize_text(text: str) -> str:
    text = text.replace("`", "")
    text = re.sub(r"\[(.*?)\]\([^)]+\)", r"\1", text)
    text = text.replace("**", "").replace("*", "")
    return text


def char_width_factor(ch: str) -> float:
    if ch in "il.,:;!'| ":
        return 0.33
    if ch in "mwMW@#%&":
        return 0.9
    if ch.isupper():
        return 0.72
    return 0.56


def estimate_width(text: str, font_size: int) -> float:
    return sum(char_width_factor(ch) for ch in text) * font_size


def wrap_line(text: str, font_size: int, max_width: int) -> list[str]:
    words = text.split()
    if not words:
        return [""]
    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        trial = f"{current} {word}"
        if estimate_width(trial, font_size) <= max_width:
            current = trial
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def parse_markdown(md_text: str) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []
    for raw in md_text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            blocks.append(("blank", ""))
            continue
        if line.startswith("### "):
            blocks.append(("h3", sanitize_text(line[4:].strip())))
            continue
        if line.startswith("## "):
            blocks.append(("h2", sanitize_text(line[3:].strip())))
            continue
        if line.startswith("# "):
            blocks.append(("h1", sanitize_text(line[2:].strip())))
            continue
        if line.startswith("- "):
            blocks.append(("bullet", sanitize_text(line[2:].strip())))
            continue
        blocks.append(("p", sanitize_text(line.strip())))
    return blocks


def emit_text(lines: list[str], x: int, y: int, font: str, size: int) -> str:
    parts = [f"BT /{font} {size} Tf 1 0 0 1 {x} {y} Tm"]
    first = True
    for line in lines:
        escaped = pdf_escape(line)
        if first:
            parts.append(f"({escaped}) Tj")
            first = False
        else:
            parts.append(f"0 -{LINE_HEIGHT} Td ({escaped}) Tj")
    parts.append("ET")
    return "\n".join(parts)


def render_pages(blocks: list[tuple[str, str]]) -> list[str]:
    pages: list[str] = []
    page_ops: list[str] = []
    y = PAGE_HEIGHT - MARGIN_TOP

    def ensure_space(height_needed: int) -> None:
        nonlocal page_ops, y
        if y - height_needed < MARGIN_BOTTOM:
            pages.append("\n".join(page_ops))
            page_ops = []
            y = PAGE_HEIGHT - MARGIN_TOP

    for kind, text in blocks:
        if kind == "blank":
            y -= 8
            continue

        if kind == "h1":
            size = 22
            font = "F2"
            lines = wrap_line(text, size, MAX_TEXT_WIDTH)
            ensure_space((len(lines) * 26) + 8)
            page_ops.append(emit_text(lines, MARGIN_X, y, font, size))
            y -= len(lines) * 26 + 8
            continue

        if kind == "h2":
            size = 16
            font = "F2"
            lines = wrap_line(text, size, MAX_TEXT_WIDTH)
            ensure_space((len(lines) * 21) + 4)
            page_ops.append(emit_text(lines, MARGIN_X, y, font, size))
            y -= len(lines) * 21 + 4
            continue

        if kind == "h3":
            size = 13
            font = "F2"
            lines = wrap_line(text, size, MAX_TEXT_WIDTH)
            ensure_space((len(lines) * 18) + 2)
            page_ops.append(emit_text(lines, MARGIN_X, y, font, size))
            y -= len(lines) * 18 + 2
            continue

        if kind == "bullet":
            bullet_text = f"- {text}"
            lines = wrap_line(bullet_text, BODY_FONT_SIZE, MAX_TEXT_WIDTH)
            ensure_space(len(lines) * LINE_HEIGHT)
            page_ops.append(emit_text(lines, MARGIN_X, y, "F1", BODY_FONT_SIZE))
            y -= len(lines) * LINE_HEIGHT
            continue

        lines = wrap_line(text, BODY_FONT_SIZE, MAX_TEXT_WIDTH)
        ensure_space(len(lines) * LINE_HEIGHT)
        page_ops.append(emit_text(lines, MARGIN_X, y, "F1", BODY_FONT_SIZE))
        y -= len(lines) * LINE_HEIGHT

    if page_ops:
        pages.append("\n".join(page_ops))
    return pages


def build_pdf(page_contents: list[str]) -> bytes:
    objects: list[bytes] = []

    def add_object(data: str | bytes) -> int:
        if isinstance(data, str):
            data = data.encode("cp1252", errors="replace")
        objects.append(data)
        return len(objects)

    font1 = add_object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    font2 = add_object("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>")

    content_ids: list[int] = []
    page_ids: list[int] = []
    for content in page_contents:
        content_bytes = content.encode("cp1252", errors="replace")
        content_id = add_object(
            b"<< /Length "
            + str(len(content_bytes)).encode("ascii")
            + b" >>\nstream\n"
            + content_bytes
            + b"\nendstream"
        )
        content_ids.append(content_id)
        page_id = add_object(
            f"<< /Type /Page /Parent 0 0 R /MediaBox [0 0 {PAGE_WIDTH} {PAGE_HEIGHT}] "
            f"/Resources << /Font << /F1 {font1} 0 R /F2 {font2} 0 R >> >> "
            f"/Contents {content_id} 0 R >>"
        )
        page_ids.append(page_id)

    kids = " ".join(f"{page_id} 0 R" for page_id in page_ids)
    pages_id = add_object(f"<< /Type /Pages /Kids [{kids}] /Count {len(page_ids)} >>")

    # backfill page parent refs
    for page_id in page_ids:
        page_obj = objects[page_id - 1].decode("cp1252")
        page_obj = page_obj.replace("/Parent 0 0 R", f"/Parent {pages_id} 0 R")
        objects[page_id - 1] = page_obj.encode("cp1252")

    catalog_id = add_object(f"<< /Type /Catalog /Pages {pages_id} 0 R >>")

    pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for idx, obj in enumerate(objects, start=1):
        offsets.append(len(pdf))
        pdf.extend(f"{idx} 0 obj\n".encode("ascii"))
        pdf.extend(obj)
        pdf.extend(b"\nendobj\n")

    xref_pos = len(pdf)
    pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    pdf.extend(b"0000000000 65535 f \n")
    for off in offsets[1:]:
        pdf.extend(f"{off:010d} 00000 n \n".encode("ascii"))
    pdf.extend(
        (
            f"trailer\n<< /Size {len(objects) + 1} /Root {catalog_id} 0 R >>\n"
            f"startxref\n{xref_pos}\n%%EOF\n"
        ).encode("ascii")
    )
    return bytes(pdf)


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python markdown_to_pdf.py <input.md> <output.pdf>")
        return 1

    source = Path(sys.argv[1])
    target = Path(sys.argv[2])
    md_text = source.read_text(encoding="utf-8")
    blocks = parse_markdown(md_text)
    pages = render_pages(blocks)
    pdf = build_pdf(pages)
    target.write_bytes(pdf)
    print(f"Wrote {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
