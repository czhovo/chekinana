import PhotosUI
import SwiftUI

struct ContentView: View {
    private let tags = ["标签一", "标签二", "标签三", "标签四"]

    @State private var selectedTag = 0
    @State private var prompt = ""
    @State private var selectedItems: [PhotosPickerItem] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                Spacer(minLength: 0)
                composer
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.light)
    }

    private var titleBar: some View {
        Text("Chekinana")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(.systemGray5))
                    .frame(height: 0.5)
            }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tags.indices, id: \.self) { index in
                        Button {
                            selectedTag = index
                        } label: {
                            Text(tags[index])
                                .font(.system(size: 14))
                                .foregroundStyle(selectedTag == index ? .black : Color(.systemGray))
                                .padding(.horizontal, 13)
                                .frame(height: 28)
                                .background(selectedTag == index ? Color(.systemGray6) : .white)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(selectedTag == index ? Color(.systemGray4) : Color(.systemGray5), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
            }

            VStack(spacing: 12) {
                TextField("Ask Chekinana...", text: $prompt, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)

                HStack {
                    PhotosPicker(selection: $selectedItems, maxSelectionCount: 9, matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 9)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 7)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color(red: 0.965, green: 0.965, blue: 0.965))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.systemGray5))
                .frame(height: 0.5)
        }
    }
}

#Preview {
    ContentView()
}
