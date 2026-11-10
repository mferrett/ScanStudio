#!/usr/bin/env python3
"""Misura il solo OCR Paddle su un'immagine scelta dall'utente, senza stampare il testo."""
import argparse
import difflib
import re
from importlib.metadata import version
from collections import Counter
import os
from pathlib import Path
from time import perf_counter


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="Immagine locale di prova")
    parser.add_argument("--detection-model-name", choices=["PP-OCRv5_mobile_det", "PP-OCRv5_server_det"], default="PP-OCRv5_mobile_det")
    parser.add_argument("--recognition-model-name", default="latin_PP-OCRv5_mobile_rec")
    parser.add_argument("--detection-model-dir", type=Path, required=True, help="Cartella locale del modello di rilevamento")
    parser.add_argument("--recognition-model-dir", type=Path, required=True, help="Cartella locale del modello latino")
    parser.add_argument("--runs", type=int, default=1, help="Numero di esecuzioni della stessa immagine")
    parser.add_argument("--reference-text", type=Path, help="Testo locale di riferimento, usato solo per stimare la somiglianza")
    args = parser.parse_args()
    if args.runs < 1 or args.runs > 20:
        parser.error("--runs deve essere compreso tra 1 e 20")
    for path in (args.image, args.detection_model_dir, args.recognition_model_dir):
        if not path.exists():
            parser.error(f"Percorso non trovato: {path}")
    # Entrambi i modelli sono indicati esplicitamente: nessun download richiesto.
    os.environ["PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK"] = "True"
    runtime_start = perf_counter()
    from paddleocr import PaddleOCR
    import paddle

    start = perf_counter()
    ocr = PaddleOCR(
        text_detection_model_name=args.detection_model_name,
        text_detection_model_dir=str(args.detection_model_dir),
        text_recognition_model_name=args.recognition_model_name,
        text_recognition_model_dir=str(args.recognition_model_dir),
        use_doc_orientation_classify=False,
        use_doc_unwarping=False,
        use_textline_orientation=False,
        device="cpu",
    )
    loaded = perf_counter()
    timings = []
    for _ in range(args.runs):
        begin = perf_counter()
        results = ocr.predict(str(args.image))
        timings.append(perf_counter() - begin)
    texts = [text for result in results for text in result.get("rec_texts", [])]
    lines = len(texts)
    print(f"PaddlePaddle: {paddle.__version__}; PaddleOCR: {version('paddleocr')}")
    print(f"Caricamento runtime: {start-runtime_start:.2f} s")
    print(f"Inizializzazione modelli: {loaded-start:.2f} s")
    print("Riconoscimento: " + ", ".join(f"{seconds:.2f} s" for seconds in timings))
    print(f"Righe rilevate: {lines}")
    if args.reference_text:
        def normalize(text): return " ".join(text.casefold().split())
        reference = normalize(args.reference_text.read_text(encoding="utf-8"))
        prediction = normalize(" ".join(texts))
        ratio = difflib.SequenceMatcher(None, reference, prediction, autojunk=False).ratio()
        print(f"Somiglianza testuale con il riferimento: {ratio * 100:.1f}% (non è una misura di accuratezza)")
        expected = Counter(re.findall(r"\w+", reference))
        actual = Counter(re.findall(r"\w+", prediction))
        overlap = sum((expected & actual).values())
        total = sum(expected.values()) + sum(actual.values())
        if total:
            print(f"Parole in comune (F1, indipendente dall'ordine): {200 * overlap / total:.1f}%")
    print("Il testo riconosciuto non viene stampato o salvato da questo script.")


if __name__ == "__main__":
    main()
