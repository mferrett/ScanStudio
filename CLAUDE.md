# ScanStudio

App nativa macOS (Swift 5 language mode, SwiftUI, macOS 14+) per acquisire documenti da scanner
tramite ImageCaptureCore, con anteprima, selezione area, regolazioni e salvataggio PDF/PNG/JPEG/TIFF.
L'interfaccia e i messaggi sono in italiano.

## Comandi

- Build debug: `swift build`
- Esecuzione: `swift run ScanStudio`
- Bundle .app firmato ad-hoc: `./build-app.sh` → `build/ScanStudio.app`
- Xcode: aprire `Package.swift`, schema ScanStudio → My Mac

## Architettura

- `ScannerManager.swift` — ICDeviceBrowser + ICScannerDeviceDelegate. Callback sul main thread.
  Flusso: select → requestOpenSession → requestSelect(unità) → overview/scan.
  Trasferimento file-based in TIFF in una cartella temporanea; ogni pagina → `onPageScanned`.
  Area di scansione in pollici; `scanAreaOriginIsTopLeft` da verificare sull'hardware reale.
- `AppModel.swift` — ObservableObject: pagine, impostazioni, regolazioni, import, salvataggio (NSSavePanel).
- `ImageProcessor.swift` — pipeline Core Image (regolazioni applicate in software, non sull'hardware).
- `ImageUtilities.swift` — caricamento ImageIO/PDF, ridimensionamento, 1 bit, rilevamento documento (Vision).
- `Exporter.swift` — PDF via CGContext (JPEG passthrough, OCR Vision con testo invisibile), TIFF multipagina, PNG/JPEG per pagina.
- `Views/` — ContentView (3 colonne): SidebarView | CenterView (ScanAreaView / PageDetailView) | PagesPanel.

## Note

- Il codice è stato scritto senza poterlo compilare: alla prima build possono emergere piccoli errori da correggere.
- Niente sandbox: non servono entitlement per ImageCaptureCore.
- Mantenere Swift 5 language mode (`swiftLanguageVersions: [.v5]`) per evitare gli errori di concorrenza stretta di Swift 6.
