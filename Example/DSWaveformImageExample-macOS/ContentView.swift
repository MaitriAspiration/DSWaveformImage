import SwiftUI
import DSWaveformImage
import DSWaveformImageViews

struct ContentView: View {
    var body: some View {
        if #available(macOS 12.0, *) {
            TabView {
                WaveformGalleryView()
                    .tabItem { Label("Static Files", systemImage: "waveform") }

                ProgressShowcase()
                    .tabItem { Label("Progress", systemImage: "play.circle.fill") }
            }
            .frame(minWidth: 520, minHeight: 640)
        } else {
            Text("at least macOS 12 is required")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
