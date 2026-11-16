#!/usr/bin/env python3
"""Render the EXPLAIN_FN / EXPLAIN_FP agent results as one PDF report.

Input: a JSON Lines file, one object per explanation, with the fields
kind (FN or FP), sample_id, variant, category, explanation, evidence, confidence.
"""
import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from xml.sax.saxutils import escape

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (KeepTogether, PageBreak, Paragraph, SimpleDocTemplate,
                                Spacer, Table, TableStyle)

KIND_TITLES = {"FN": "False negatives", "FP": "False positives"}


def variant_key(v):
    """Sort CHROM:POS:REF:ALT by chromosome, then position."""
    parts = v["variant"].split(":")
    chrom = parts[0].removeprefix("chr")
    pos = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    return (0, int(chrom), pos) if chrom.isdigit() else (1, chrom, pos)


def unicode_font():
    """Embed DejaVu (conda-forge font-ttf-dejavu-sans-mono) for the agents' text.

    The built-in PDF fonts only cover Latin-1, and the agents often write
    symbols such as >=, -> and ~ as Unicode characters.
    """
    path = os.path.join(sys.prefix, "fonts", "DejaVuSans.ttf")
    if not os.path.exists(path):
        print(f"warning: {path} not found; non-Latin-1 characters may not render", file=sys.stderr)
        return "Helvetica"
    pdfmetrics.registerFont(TTFont("DejaVu", path))
    return "DejaVu"


def para(text, style):
    """Escape agent text for reportlab's mini-markup and keep line breaks."""
    return Paragraph(escape(str(text)).replace("\n", "<br/>"), style)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("rows", help="JSON Lines file of explanations")
    ap.add_argument("-o", "--output", default="explanations.pdf")
    ap.add_argument("--title", default="hap.py false negative / false positive explanations")
    args = ap.parse_args()

    with open(args.rows) as fh:
        rows = [json.loads(line) for line in fh if line.strip()]

    font = unicode_font()
    styles = getSampleStyleSheet()
    body = ParagraphStyle("body", parent=styles["BodyText"], fontName=font, fontSize=9, leading=12.5,
                          alignment=TA_LEFT)
    small = ParagraphStyle("small", parent=body, fontSize=7.5, leading=10, textColor=colors.HexColor("#444444"))
    quote = ParagraphStyle("quote", parent=small, backColor=colors.HexColor("#f4f4f4"), borderPadding=4)
    head = ParagraphStyle("head", parent=styles["Heading4"], fontSize=10.5, spaceAfter=2, spaceBefore=0)

    grid = TableStyle([
        ("FONTSIZE", (0, 0), (-1, -1), 8.5),
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e8e8e8")),
        ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#bbbbbb")),
        ("ALIGN", (1, 1), (-1, -1), "RIGHT"),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ])

    story = [
        Paragraph(escape(args.title), styles["Title"]),
        Paragraph(f"Generated {datetime.now(timezone.utc):%Y-%m-%d %H:%M} UTC. "
                  f"{len(rows)} explanation(s) written by the LLM agents from the evidence "
                  "gathered around each call. Treat them as hypotheses to check, not findings.", small),
        Spacer(1, 6 * mm),
    ]

    # Summary: explanations per sample and kind, then categories per kind.
    kinds = [k for k in ("FN", "FP") if any(r["kind"] == k for r in rows)]
    samples = sorted({r["sample_id"] for r in rows})
    story.append(Paragraph("Summary", styles["Heading2"]))
    table = [["Sample"] + [KIND_TITLES[k] for k in kinds]]
    for s in samples:
        table.append([s] + [sum(1 for r in rows if r["sample_id"] == s and r["kind"] == k) for k in kinds])
    story += [Table(table, hAlign="LEFT", style=grid), Spacer(1, 4 * mm)]

    for k in kinds:
        counts = Counter(r["category"] for r in rows if r["kind"] == k)
        table = [[f"{KIND_TITLES[k]}: category", "Count", "Mean confidence"]]
        for cat, n in counts.most_common():
            confs = [float(r["confidence"]) for r in rows if r["kind"] == k and r["category"] == cat]
            table.append([cat, n, f"{sum(confs) / len(confs):.2f}"])
        story += [Table(table, hAlign="LEFT", style=grid), Spacer(1, 4 * mm)]

    # Details: one section per kind, grouped by sample, ordered by position.
    for k in kinds:
        story += [PageBreak(), Paragraph(KIND_TITLES[k], styles["Heading1"])]
        by_sample = defaultdict(list)
        for r in rows:
            if r["kind"] == k:
                by_sample[r["sample_id"]].append(r)
        for s in sorted(by_sample):
            story.append(Paragraph(f"Sample {escape(s)}", styles["Heading2"]))
            for r in sorted(by_sample[s], key=variant_key):
                story.append(KeepTogether([
                    Paragraph(f"{escape(r['variant'])} &nbsp;&middot;&nbsp; <b>{escape(r['category'])}</b>"
                              f" &nbsp;&middot;&nbsp; confidence {float(r['confidence']):.2f}", head),
                    para(r["explanation"], body),
                    Spacer(1, 1.5 * mm),
                    Paragraph("Evidence cited", small),
                    para(r["evidence"], quote),
                    Spacer(1, 5 * mm),
                ]))

    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(colors.grey)
        canvas.drawRightString(A4[0] - 15 * mm, 10 * mm, f"Page {doc.page}")
        canvas.restoreState()

    SimpleDocTemplate(args.output, pagesize=A4, leftMargin=15 * mm, rightMargin=15 * mm,
                      topMargin=15 * mm, bottomMargin=18 * mm, title=args.title
                      ).build(story, onFirstPage=footer, onLaterPages=footer)


if __name__ == "__main__":
    main()
