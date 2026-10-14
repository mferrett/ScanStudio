import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(scanner: model.scanner)
                .frame(width: 400)
            Divider()
            CenterView(scanner: model.scanner)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PagesPanel()
                .frame(width: 230)
        }
        .overlay {
            if let message = model.busyMessage {
                BusyOverlay(message: message, progress: model.busyProgress)
            }
        }
        .alert("ScanStudio", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

#Preview("ContentView") {
    ContentView()
        .environmentObject(AppModel())
        .frame(width: 1320, height: 840)
}
