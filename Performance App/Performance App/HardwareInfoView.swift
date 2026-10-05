import SwiftUI

struct HardwareInfoView: View {
    @State private var sections = HardwareInfo.load() + GPUInfo.load()

    var body: some View {
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        LabeledContent(item.label, value: item.value)
                    }
                }
            }
        }
        .navigationTitle("Hardware Info")
        .frame(minWidth: 340, minHeight: 400)
    }
}

#Preview {
    HardwareInfoView()
}
