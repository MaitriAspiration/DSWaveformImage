import SwiftUI
import DSWaveformImage
import DSWaveformImageViews

struct ContentView: View {
    var body: some View {
        if #available(macOS 12.0, *) {
            WaveformGalleryView()
                .frame(minWidth: 480, minHeight: 600)
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
