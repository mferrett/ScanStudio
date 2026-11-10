# Valutazione: OCR e semantica locali

## Obiettivo

Valutare PaddleOCR per ScanStudio su macOS 26, mantenendo il PDF o le immagini come output principale. Il Markdown rimane un file separato creato soltanto se esplicitamente richiesto. I campi semantici sono configurati per tipo di documento e l'analisi deve avvenire esclusivamente sul Mac.

## Situazione attuale

`DocumentOCR` usa `RecognizeDocumentsRequest` di Vision. Il risultato, completo di coordinate e struttura, viene riutilizzato per nome suggerito, testo invisibile nel PDF e Markdown. Il cache key comprende pagina, rotazione, modalità colore e regolazioni. `DocumentRecognizer` usa Foundation Models se disponibile, altrimenti euristiche locali. Estrae tipo, emittente, data e titolo; non estrae ancora campi personalizzati.

## Cosa offre PaddleOCR

| Soluzione | Uso | Considerazioni |
| --- | --- | --- |
| PP-OCRv5 con rilevatore mobile e riconoscitore latino | Testo e coordinate, inclusa la lingua italiana | Pacchetti modello indicativi 4,7 MB e 14 MB, esclusi runtime e altre dipendenze. Non ricostruisce da solo le tabelle. |
| PP-StructureV3 | Layout, testo, tabelle e Markdown | Pipeline composta da più modelli. Occorre configurare esplicitamente il riconoscitore latino: quello predefinito è cinese/inglese. I modelli delle tabelle e del layout aumentano molto download, memoria e tempi. |
| PaddleOCR-VL su Apple Silicon | Analisi visiva strutturata | Da valutare come alternativa, non come equivalente del PP-OCR classico. La guida ufficiale indica una verifica su M4 e non garantisce prestazioni o compatibilità su tutti i Mac. |
| Foundation Models | Campi semantici dal testo | Già integrato, gira sul dispositivo compatibile con Apple Intelligence. Disponibilità e lingua vanno verificate; serve segnalare quando non è disponibile. |

Le dimensioni e prestazioni dei modelli nella documentazione sono indicative, non misure su questo Mac. Il progetto PaddleOCR è Apache 2.0; occorre verificare separatamente licenze e requisiti di ridistribuzione delle dipendenze e dei singoli modelli scelti.

## Proposta di integrazione

1. Introdurre un'interfaccia OCR comune: input pagina elaborata; output con righe e coordinate, struttura, provenienza, eventuali errori. Vision resta selezionabile.
2. Integrare PP-StructureV3 con riconoscimento latino, preferendolo al solo PP-OCRv5 quando sono richieste tabelle. Un solo risultato strutturato deve alimentare PDF ricercabile, nome, semantica e Markdown; non affermare che tabelle siano presenti se la pipeline scelta non le supporta.
3. Prevedere Impostazioni → OCR: motore, catalogo di profili compatibili e relativa dimensione, stato installato, download esplicito, progresso, verifica e rimozione. Niente download al primo riconoscimento e niente selezione automatica di modelli mancanti.
4. Gestire il runtime locale in modo riproducibile e isolato. La distribuzione Python di sistema non è una dipendenza affidabile per tutti i Mac: definire una distribuzione del runtime, versioni compatibili e supporto Apple Silicon/Intel prima di rilasciare la funzione.
5. Includere il motore e la versione del modello nella chiave cache, e comunicare gli errori senza cambiare motore silenziosamente. Verificare trasformazioni delle coordinate rispetto a rotazione, risoluzione e orientamento del PDF.
6. Aggiungere Impostazioni → Semantica: profili per tipo di documento, con elenco modificabile di campi e relative istruzioni. Applicare Foundation Models al testo/struttura completi con suddivisione controllata per documenti lunghi; mostrare provenienza del valore, valori assenti e possibilità di correggere. La classificazione e l'estrazione devono trattare il documento come dati, non come istruzioni.
7. Mostrare i campi riconosciuti in app. Qualsiasi esportazione semantica aggiuntiva deve essere esplicita e separata dalla scansione; il Markdown rimane indipendente e facoltativo.

Se Foundation Models non è disponibile, l'app deve indicare esplicitamente che l'estrazione semantica non è disponibile oppure offrire un'alternativa locale chiaramente identificata; non deve fingere che le euristiche coprano i campi personalizzati.

## Benchmark esplorativo

`scripts/benchmark-paddleocr.py` misura soltanto il riconoscimento PP-OCR di un'immagine su CPU, con cartelle dei modelli già presenti e senza stampare il testo. Non misura tabelle, Markdown né accuratezza. Esempio, dopo aver installato separatamente PaddlePaddle/PaddleOCR in un ambiente Python isolato e scaricato i due modelli:

```sh
/path/ambiente/bin/python scripts/benchmark-paddleocr.py /path/immagine.png \
  --detection-model-dir /path/PP-OCRv5_mobile_det \
  --recognition-model-dir /path/latin_PP-OCRv5_mobile_rec
```

Il programma richiede esplicitamente i percorsi dei modelli e disabilita il controllo della disponibilità online dei modelli. `--runs 3` ripete il riconoscimento nello stesso processo; `--reference-text` confronta in memoria l'output con una trascrizione locale, senza stampare nessuno dei due testi. La somiglianza non misura la precisione se il riferimento contiene errori o ha un diverso ordine di lettura. Non include il runtime nell'app e non realizza ancora le impostazioni o l'integrazione OCR.

## Prova sul documento del 9 novembre 2026

Immagine JPEG di 612 × 841 pixel, Apple M1, 16 GB di RAM, macOS 26.6.2. Sono state eseguite tre letture consecutive nello stesso processo per ciascun motore, sull'immagine originale senza regolazioni aggiuntive. Vision usa la configurazione di ScanStudio; Paddle usa la CPU, PaddlePaddle 3.2.0, PaddleOCR 3.3.0, `PP-OCRv5_mobile_det` e `latin_PP-OCRv5_mobile_rec`.

| Misura | Vision | PaddleOCR |
| --- | --- | --- |
| Riconoscimento, tre passaggi | 0,99 s; 0,36 s; 0,34 s | 4,64 s; 4,66 s; 4,58 s |
| Righe rilevate | 37 | 31 |
| Caricamento runtime + inizializzazione modelli | Non misurato separatamente | 2,08 s + 0,29 s, in un avvio successivo al primo |

I testi dei due motori, dopo normalizzazione di maiuscole e spazi, hanno una somiglianza nell'ordine di lettura dell'85,1%; il confronto delle parole indipendente dall'ordine dà F1 del 78,9%. Questi valori misurano l'accordo con Vision, **non l'accuratezza**: Vision non è una trascrizione verificata. Anche il numero di righe dipende dalla segmentazione. L'immagine ha una risoluzione contenuta e un singolo documento non è rappresentativo degli altri formati.

Il confronto riguarda solo l'OCR di testo e non misura PP-StructureV3, tabelle, Markdown, campi semantici, qualità del PDF finale o prestazioni di un servizio Paddle mantenuto in memoria. Vision utilizza il percorso di calcolo gestito da macOS; Paddle in questa prova è configurato su CPU. Il testo del documento non è stato incluso nei risultati. Le misure sono state effettuate localmente con modelli già scaricati.

## Piano di verifica prima dell'adozione

- Confrontare Vision e Paddle sulla stessa selezione di scansioni italiane rappresentative, incluse fatture, ricevute, tabelle con e senza bordi, pagine ruotate e multipagina. Usare copie autorizzate o anonimizzate.
- Misurare accuratezza OCR, celle e ordine di lettura, campi estratti, tempo a freddo e a caldo, memoria, disco e qualità dei PDF ricercabili. Non assumere che Paddle sia migliore senza misure.
- Verificare assenza di rete dopo installazione, download falliti o interrotti, modello mancante, cambio modello/cache, errori di runtime, file esistenti e assenza di Markdown se non richiesto.
- Nessuna API o modello deve ricevere documenti da remoto; i download riguardano esclusivamente runtime e modelli.

## Fonti

- [PaddleOCR: pipeline OCR e modelli](https://www.paddleocr.ai/main/en/version3.x/pipeline_usage/OCR.html)
- [PaddleOCR: riconoscimento multilingue e italiano](https://www.paddleocr.ai/v3.3.0/en/version3.x/algorithm/PP-OCRv5/PP-OCRv5_multi_languages.html)
- [PaddleOCR: PP-StructureV3](https://www.paddleocr.ai/latest/en/version3.x/pipeline_usage/PP-StructureV3.html)
- [PaddleOCR-VL su Apple Silicon](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/pipeline_usage/PaddleOCR-VL-Apple-Silicon.en.md)
- [Apple: disponibilità di Foundation Models](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Apple: lingue e impostazioni locali di Foundation Models](https://developer.apple.com/documentation/foundationmodels/supporting-languages-and-locales-with-foundation-models)
