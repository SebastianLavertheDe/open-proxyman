import SwiftUI

struct ClientIconView: View {
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }
}
