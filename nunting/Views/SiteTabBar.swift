import SwiftUI

struct SiteTabBar: View {
    let tabs: [TopTab]
    @Binding var selection: TopTab

    @Namespace private var underlineNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        tabButton(tab: tab)
                            .id(tab.id)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(newValue.id, anchor: .center)
                }
            }
        }
    }

    private func tabButton(tab: TopTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 6) {
                Text(tab.displayName)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                ZStack {
                    Rectangle().fill(Color.clear).frame(height: 2)
                    if isSelected {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underlineNamespace)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
