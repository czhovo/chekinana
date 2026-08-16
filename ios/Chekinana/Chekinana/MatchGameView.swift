import AVFoundation
import SwiftUI
import UIKit

struct ChekinanaLianliankanView: View {
    @StateObject private var model = ChekinanaMatchGameViewModel()
    let onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            HStack(spacing: 10) {
                                MatchGameStatPill(title: "时间", value: model.formattedTime)
                                MatchGameStatPill(title: "剩余", value: "\(model.engine.remainingPairs)")
                            }

                            HStack(spacing: 10) {
                                Button("重置") {
                                    model.reset()
                                }
                                .buttonStyle(MatchGameControlButtonStyle(color: Color(red: 0.11, green: 0.31, blue: 0.72)))

                                Button(model.isAutoSolving ? "暂停" : "解答") {
                                    model.toggleAnswer()
                                }
                                .buttonStyle(MatchGameControlButtonStyle(color: Color(red: 0.05, green: 0.60, blue: 0.83)))
                                .disabled(!model.canToggleAnswer)
                                .opacity(model.canToggleAnswer ? 1 : 0.46)
                            }
                            .frame(maxWidth: 250)

                            MatchGameBoardView(
                                model: model,
                                maximumHeight: boardMaximumHeight(in: viewport.size.height)
                            )

                            if !model.statusText.isEmpty {
                                Text(model.statusText)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color(red: 0.12, green: 0.28, blue: 0.63))
                                    .frame(maxWidth: .infinity)
                                    .transition(.opacity)
                            }

                            if model.engine.isComplete {
                                MatchGameAudioPlayerView(player: model.audioPlayer)
                                    .id("match-game-audio")
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.engine.isComplete) { _, isComplete in
                        guard isComplete else { return }
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo("match-game-audio", anchor: .bottom)
                        }
                    }
                    .task(id: model.engine.isComplete) {
                        guard model.engine.isComplete else { return }
                        await Task.yield()
                        proxy.scrollTo("match-game-audio", anchor: .bottom)
                    }
                }
            }
            .background(Color(red: 0.96, green: 0.97, blue: 1).ignoresSafeArea())
            .navigationTitle("连连看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("关闭连连看")
                    .accessibilityIdentifier("chekinana.match-game.close")
                }
            }
        }
        .onAppear {
            model.activate()
        }
        .onDisappear {
            model.deactivate()
        }
    }

    private func boardMaximumHeight(in viewportHeight: CGFloat) -> CGFloat {
        let reservedHeight: CGFloat = model.engine.isComplete ? 280 : 150
        return max(180, viewportHeight - reservedHeight)
    }
}

private struct MatchGameStatPill: View {
    let title: String
    let value: String

    var body: some View {
        Text("\(title)  \(value)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color(red: 0.12, green: 0.31, blue: 0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(red: 0.86, green: 0.92, blue: 1), in: Capsule())
    }
}

private struct MatchGameControlButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(color.opacity(configuration.isPressed ? 0.76 : 1), in: RoundedRectangle(cornerRadius: 13))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct MatchGameBoardView: View {
    @ObservedObject var model: ChekinanaMatchGameViewModel
    let maximumHeight: CGFloat

    private let spacing: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            // Reserve half a tile on every edge for legal outside-board paths.
            // This also makes the playing tiles slightly smaller without
            // changing the 12 x 8 board or its hit targets.
            let cellSize = (
                geometry.size.width
                    - spacing * CGFloat(MatchGameEngine.columnCount - 1)
            ) / CGFloat(MatchGameEngine.columnCount + 1)
            let outsideInset = cellSize / 2
            let gridWidth = cellSize * CGFloat(MatchGameEngine.columnCount)
                + spacing * CGFloat(MatchGameEngine.columnCount - 1)
            let gridHeight = cellSize * CGFloat(MatchGameEngine.rowCount)
                + spacing * CGFloat(MatchGameEngine.rowCount - 1)
            let boardHeight = gridHeight + cellSize
            let columns = Array(
                repeating: GridItem(.fixed(cellSize), spacing: spacing),
                count: MatchGameEngine.columnCount
            )

            ZStack {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(0..<(MatchGameEngine.rowCount * MatchGameEngine.columnCount), id: \.self) { index in
                        let position = MatchGamePosition(
                            row: index / MatchGameEngine.columnCount,
                            column: index % MatchGameEngine.columnCount
                        )
                        MatchGameTileButton(
                            tile: model.engine.tile(at: position),
                            assetID: model.assetID(for: model.engine.tile(at: position)),
                            isSelected: model.selected == position
                        ) {
                            model.tap(position)
                        }
                        .frame(height: cellSize)
                    }
                }
                .frame(width: gridWidth, height: gridHeight)
                .position(
                    x: geometry.size.width / 2,
                    y: outsideInset + gridHeight / 2
                )

                if let path = model.visiblePath, path.count >= 2 {
                    MatchGameConnectionPath(
                        path: path,
                        spacing: spacing,
                        cellSize: cellSize,
                        outsideInset: outsideInset
                    )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: boardHeight)
        }
        .aspectRatio(
            MatchGameBoardView.layoutAspectRatio,
            contentMode: .fit
        )
        .frame(maxWidth: maximumHeight * Self.layoutAspectRatio)
        .padding(.vertical, 2)
        .accessibilityIdentifier("chekinana.match-game.board")
    }

    private static let layoutAspectRatio: CGFloat = {
        let referenceCell: CGFloat = 20
        let spacing: CGFloat = 5
        let width = referenceCell * CGFloat(MatchGameEngine.columnCount + 1)
            + spacing * CGFloat(MatchGameEngine.columnCount - 1)
        let height = referenceCell * CGFloat(MatchGameEngine.rowCount + 1)
            + spacing * CGFloat(MatchGameEngine.rowCount - 1)
        return width / height
    }()
}

private struct MatchGameTileButton: View {
    let tile: Int
    let assetID: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tile == 0 ? Color.clear : MatchGameBundleAssets.backgroundColor(for: assetID))
                    .shadow(
                        color: tile == 0 ? .clear : Color(red: 0.12, green: 0.28, blue: 0.62).opacity(0.10),
                        radius: 3,
                        y: 2
                    )

                if tile == 0 {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            Color(red: 0.58, green: 0.75, blue: 0.96).opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                } else if let image = MatchGameBundleAssets.image(for: assetID) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(1)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color(red: 0.12, green: 0.38, blue: 0.91), lineWidth: 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(tile == 0)
        .accessibilityLabel(tile == 0 ? "空白" : "图案 \(assetID)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MatchGameConnectionPath: View {
    let path: [MatchGamePosition]
    let spacing: CGFloat
    let cellSize: CGFloat
    let outsideInset: CGFloat

    var body: some View {
        Canvas { context, size in
            func point(for position: MatchGamePosition) -> CGPoint {
                let x: CGFloat
                if position.column < 0 {
                    x = 0
                } else if position.column >= MatchGameEngine.columnCount {
                    x = size.width
                } else {
                    x = outsideInset
                        + CGFloat(position.column) * (cellSize + spacing)
                        + cellSize / 2
                }

                let y: CGFloat
                if position.row < 0 {
                    y = 0
                } else if position.row >= MatchGameEngine.rowCount {
                    y = size.height
                } else {
                    y = outsideInset
                        + CGFloat(position.row) * (cellSize + spacing)
                        + cellSize / 2
                }
                return CGPoint(x: x, y: y)
            }

            var line = Path()
            line.move(to: point(for: path[0]))
            for position in path.dropFirst() {
                line.addLine(to: point(for: position))
            }
            context.stroke(
                line,
                with: .linearGradient(
                    Gradient(colors: [Color(red: 0.57, green: 0.76, blue: 1), Color(red: 0.12, green: 0.38, blue: 0.91)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)
                ),
                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

@MainActor
final class ChekinanaMatchGameViewModel: ObservableObject {
    @Published private(set) var engine: MatchGameEngine
    @Published private(set) var selected: MatchGamePosition?
    @Published private(set) var visiblePath: [MatchGamePosition]?
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var statusText = ""
    @Published private(set) var isAutoSolving = false
    @Published private(set) var isSolving = false

    let audioPlayer = ChekinanaMatchGameAudioPlayer()

    private var boardIndex: Int
    private var assetIDsByTile: [Int]
    private var isAnimatingMove = false
    private var timerTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var solveTask: Task<Void, Never>?

    init(initialBoardIndex: Int? = nil) {
#if DEBUG
        if ProcessInfo.processInfo.environment["CHEKINANA_MATCH_GAME_UI_COMPLETE"] == "1" {
            boardIndex = 0
            engine = MatchGameEngine(
                board: Array(
                    repeating: Array(repeating: 0, count: MatchGameEngine.columnCount),
                    count: MatchGameEngine.rowCount
                )
            )
            assetIDsByTile = [0] + Array(1...14)
            return
        }
#endif
        let index = initialBoardIndex.map { abs($0) % MatchGamePresetBoards.all.count }
            ?? Int.random(in: MatchGamePresetBoards.all.indices)
        boardIndex = index
        engine = MatchGameEngine(board: MatchGamePresetBoards.all[index])
        assetIDsByTile = [0] + Array(1...14).shuffled()
    }

    var formattedTime: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    var canToggleAnswer: Bool {
        isAutoSolving || (!engine.isComplete && !isAnimatingMove && !isSolving)
    }

    func assetID(for tile: Int) -> Int {
        assetIDsByTile.indices.contains(tile) ? assetIDsByTile[tile] : 0
    }

    func activate() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if !self.engine.isComplete {
                    self.elapsedSeconds += 1
                }
            }
        }
    }

    func deactivate() {
        timerTask?.cancel()
        timerTask = nil
        moveTask?.cancel()
        moveTask = nil
        pauseAutoSolve(showMessage: false)
        audioPlayer.pause()
    }

    func reset() {
        moveTask?.cancel()
        solveTask?.cancel()
        boardIndex = (boardIndex + 1) % MatchGamePresetBoards.all.count
        engine = MatchGameEngine(board: MatchGamePresetBoards.all[boardIndex])
        assetIDsByTile = [0] + Array(1...14).shuffled()
        selected = nil
        visiblePath = nil
        elapsedSeconds = 0
        statusText = ""
        isAutoSolving = false
        isSolving = false
        isAnimatingMove = false
        audioPlayer.reset()
    }

    func tap(_ position: MatchGamePosition) {
        guard !engine.isComplete, !isAnimatingMove, !isAutoSolving, !isSolving else { return }
        guard engine.tile(at: position) != 0 else { return }

        guard let first = selected else {
            selected = position
            statusText = ""
            return
        }

        if first == position {
            selected = nil
            statusText = ""
            return
        }

        guard engine.tile(at: first) == engine.tile(at: position) else {
            selected = nil
            statusText = "图片不同"
            return
        }

        guard let path = engine.connectionPath(from: first, to: position) else {
            selected = nil
            statusText = "路径不合法"
            return
        }

        selected = nil
        statusText = ""
        visiblePath = path
        isAnimatingMove = true
        let move = MatchGameMove(first: first, second: position, path: path)
        moveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 420_000_000)
                guard let self, !Task.isCancelled else { return }
                _ = self.engine.remove(move)
                self.visiblePath = nil
                self.isAnimatingMove = false
                self.moveTask = nil
                self.handleVictoryIfNeeded()
            } catch {
                self?.visiblePath = nil
                self?.isAnimatingMove = false
            }
        }
    }

    func toggleAnswer() {
        if isAutoSolving || isSolving {
            pauseAutoSolve(showMessage: true)
        } else {
            startAutoSolve()
        }
    }

    private func startAutoSolve() {
        guard !engine.isComplete, !isAnimatingMove else { return }
        selected = nil
        visiblePath = nil
        statusText = "正在求解…"
        isSolving = true
        let snapshot = engine

        solveTask = Task { [weak self] in
            let solution = await Task.detached(priority: .userInitiated) {
                MatchGameSolver.solution(for: snapshot)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.isSolving = false
            guard let solution else {
                self.statusText = "当前棋盘无解"
                self.solveTask = nil
                return
            }

            self.isAutoSolving = true
            self.statusText = ""
            await self.play(solution)
            self.solveTask = nil
        }
    }

    private func play(_ solution: [MatchGameMove]) async {
        for proposedMove in solution {
            guard !Task.isCancelled, isAutoSolving else { return }
            guard let path = engine.connectionPath(from: proposedMove.first, to: proposedMove.second) else {
                continue
            }

            let move = MatchGameMove(first: proposedMove.first, second: proposedMove.second, path: path)
            visiblePath = path
            isAnimatingMove = true
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                visiblePath = nil
                isAnimatingMove = false
                return
            }
            guard !Task.isCancelled, isAutoSolving else {
                visiblePath = nil
                isAnimatingMove = false
                return
            }

            _ = engine.remove(move)
            visiblePath = nil
            isAnimatingMove = false
            if engine.isComplete {
                isAutoSolving = false
                handleVictoryIfNeeded()
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        isAutoSolving = false
        if !engine.isComplete {
            statusText = "解答已结束"
        }
    }

    private func pauseAutoSolve(showMessage: Bool) {
        solveTask?.cancel()
        solveTask = nil
        isAutoSolving = false
        isSolving = false
        isAnimatingMove = false
        visiblePath = nil
        if showMessage {
            statusText = "已暂停"
        }
    }

    private func handleVictoryIfNeeded() {
        guard engine.isComplete else { return }
        selected = nil
        visiblePath = nil
        isAutoSolving = false
        isSolving = false
        statusText = "完成！"
        audioPlayer.playFromBeginning()
    }
}

@MainActor
final class ChekinanaMatchGameAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorText = ""

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    var progress: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    func playFromBeginning() {
        reset()
        guard let url = MatchGameBundleAssets.victoryAudioURL else {
            errorText = "本地音频不可用"
            return
        }

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.prepareToPlay()
            player = audioPlayer
            duration = audioPlayer.duration
            audioPlayer.currentTime = 0
            audioPlayer.play()
            isPlaying = true
            startProgressUpdates()
        } catch {
            errorText = "本地音频无法播放"
        }
    }

    func togglePlayback() {
        guard let player else {
            playFromBeginning()
            return
        }

        if player.isPlaying {
            pause()
        } else {
            if player.currentTime >= max(0, player.duration - 0.05) {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
            startProgressUpdates()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        progressTask?.cancel()
        progressTask = nil
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to progress: Double) {
        guard let player, duration > 0 else { return }
        let clampedProgress = min(1, max(0, progress))
        player.currentTime = duration * clampedProgress
        currentTime = player.currentTime
    }

    func reset() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        errorText = ""
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}

private struct MatchGameAudioPlayerView: View {
    @ObservedObject var player: ChekinanaMatchGameAudioPlayer

    var body: some View {
        HStack(spacing: 14) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(Color(red: 0.12, green: 0.38, blue: 0.91))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")

            VStack(alignment: .leading, spacing: 3) {
                Text("目光 - 空色轨迹")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.31, blue: 0.75))

                if !player.errorText.isEmpty {
                    Text(player.errorText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { player.progress },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...1
                )
                .tint(Color(red: 0.12, green: 0.38, blue: 0.91))
                .disabled(player.duration <= 0)

                HStack {
                    Text(Self.format(player.currentTime))
                    Spacer()
                    Text(Self.format(player.duration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
        .accessibilityIdentifier("chekinana.match-game.audio-player")
    }

    private static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let seconds = Int(time.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private enum MatchGameBundleAssets {
    private static let imageFiles = [
        "",
        "pattern1r", "pattern2p", "pattern3s", "pattern4g", "pattern5k", "pattern6b", "pattern7w",
        "pattern8g", "pattern9s", "pattern10p", "pattern11y", "pattern12k", "pattern13r", "pattern14w",
    ]

    private static let cachedImages: [Int: UIImage] = {
        var images: [Int: UIImage] = [:]
        for assetID in 1..<imageFiles.count {
            guard let url = Bundle.main.url(
                forResource: imageFiles[assetID],
                withExtension: "png",
                subdirectory: "MatchGame/Images"
            ), let image = UIImage(contentsOfFile: url.path) else {
                continue
            }
            images[assetID] = image
        }
        return images
    }()

    static func image(for assetID: Int) -> UIImage? {
        cachedImages[assetID]
    }

    static var victoryAudioURL: URL? {
        Bundle.main.url(
            forResource: "muguang",
            withExtension: "m4a",
            subdirectory: "MatchGame/Audio"
        )
    }

    static func backgroundColor(for assetID: Int) -> Color {
        switch assetID {
        case 1, 13:
            Color(red: 0.94, green: 0.48, blue: 0.48)
        case 2, 10:
            Color(red: 0.87, green: 0.84, blue: 0.99)
        case 3, 9:
            Color(red: 0.75, green: 0.86, blue: 0.98)
        case 4, 8:
            Color(red: 0.73, green: 0.97, blue: 0.82)
        case 5, 12:
            Color(red: 0.98, green: 0.81, blue: 0.91)
        case 6:
            Color(red: 0.38, green: 0.65, blue: 0.96)
        case 7, 14:
            Color(red: 0.97, green: 0.98, blue: 1)
        case 11:
            Color(red: 0.99, green: 0.94, blue: 0.55)
        default:
            Color(red: 0.86, green: 0.92, blue: 1)
        }
    }
}
