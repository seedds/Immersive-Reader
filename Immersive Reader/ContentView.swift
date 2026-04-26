//
//  ContentView.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ReadiumShared

struct ContentView: View {
    @StateObject private var uploadServer = UploadServerController()
    @SwiftUI.AppStorage(ReaderSettings.themeKey) private var themeRawValue = AppThemeOption.system.rawValue

    var body: some View {
        TabView {
            BooksView()
                .tabItem {
                    Label("Books", systemImage: "books.vertical")
                }

            UploadView(controller: uploadServer)
                .tabItem {
                    Label("Upload", systemImage: "network")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .preferredColorScheme(ReaderSettings.appTheme(from: themeRawValue).preferredColorScheme)
    }
}

private struct BooksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.importedAt, order: .reverse) private var books: [Book]

    @State private var isImporting = false
    @State private var isRefreshing = false
    @State private var refreshProgress = 0.0
    @State private var refreshStatus = ""
    @State private var importError: String?
    @State private var selectedBook: Book?

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView {
                        Label("No EPUB Books", systemImage: "book.closed")
                    } description: {
                        Text("Import EPUB3 books to start building your read-aloud library.")
                    } actions: {
                        Button("Import EPUB") {
                            isImporting = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(books) { book in
                            BookRow(book: book)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedBook = book
                                }
                        }
                        .onDelete(perform: deleteBooks)
                    }
                }
            }
            .allowsHitTesting(!isRefreshing)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshBooks()
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)
                    .accessibilityLabel("Refresh Books")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Import EPUB", systemImage: "plus")
                    }
                    .disabled(isRefreshing)
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { importError != nil },
                    set: { isPresented in
                        if !isPresented {
                            importError = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "Unknown error")
            }
            .navigationDestination(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .overlay {
                if isRefreshing {
                    refreshOverlay
                }
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            try BookImportService.importBooks(from: urls, modelContext: modelContext)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func deleteBooks(at offsets: IndexSet) {
        let fileManager = FileManager.default

        for index in offsets {
            let book = books[index]
            try? fileManager.removeItem(atPath: book.epubFilePath)
            try? fileManager.removeItem(atPath: book.extractedDirectoryPath)
            modelContext.delete(book)
        }

        try? modelContext.save()
    }

    private func refreshBooks() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        refreshProgress = 0
        refreshStatus = "Starting refresh..."

        Task {
            defer {
                isRefreshing = false
                refreshStatus = ""
            }

            do {
                try await BookImportService.refreshBooksFromDocuments(modelContext: modelContext) { progress in
                    refreshProgress = progress.fractionCompleted
                    refreshStatus = progress.message
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var refreshOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: refreshProgress)
                    .tint(.accentColor)

                Text(refreshStatus)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("\(Int(refreshProgress * 100))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
            }
            .padding(.horizontal, 24)
        }
    }

}

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 14) {
            BookCoverView(book: book)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(book.author)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if (book.mediaOverlayClipCount ?? 0) > 0 {
                    Image(systemName: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .accessibilityLabel("Read aloud ready")
                }

                BookProgressRing(progress: readingProgress)
            }
        }
        .padding(.vertical, 2)
    }

    private var readingProgress: Double {
        guard let lastLocatorJSON = book.lastLocatorJSON,
              let locator = try? Locator(jsonString: lastLocatorJSON)
        else {
            return 0
        }

        let progress = locator.locations.totalProgression ?? locator.locations.progression ?? 0
        return min(max(progress, 0), 1)
    }
}

private struct BookProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(.quaternary)

            ProgressPieSlice(progress: progress)
                .fill(Color.accentColor)
        }
        .frame(width: 18, height: 18)
        .overlay {
            Circle()
                .stroke(.black.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement()
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

private struct ProgressPieSlice: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else {
            return Path()
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle.degrees(-90)
        let endAngle = Angle.degrees(-90 + (360 * clampedProgress))

        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct BookCoverView: View {
    let book: Book

    var body: some View {
        Group {
            if let image = coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.blue.gradient)
                    .overlay {
                        Image(systemName: "book.closed.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 44, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }

    private var coverImage: UIImage? {
        guard let coverImagePath = book.coverImagePath else {
            return nil
        }
        return UIImage(contentsOfFile: coverImagePath)
    }
}

private struct UploadView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var controller: UploadServerController

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Status", value: controller.status.title)

                    if let serverURL = controller.serverURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Open this address on another computer on the same Wi-Fi network:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(serverURL.absoluteString)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } else if case .running = controller.status {
                        Text("Server is running, but no Wi-Fi IP address was found. Make sure this device is connected to the same network as the computer uploading the EPUB.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        switch controller.status {
                        case .running:
                            controller.stop()
                        case .stopped, .failed:
                            controller.start(modelContext: modelContext)
                        }
                    } label: {
                        Text(controller.status == .running ? "Stop Server" : "Start Server")
                    }
                }

                if case .failed(let message) = controller.status {
                    Section("Error") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Storage") {
                    Text("Uploaded EPUBs are stored directly in the app's Documents folder and should appear in Files under On My iPhone/ImmersiveReader.")
                    Text("Keep the app open while uploading. iOS may suspend local networking in the background.")
                        .foregroundStyle(.secondary)
                }

                if !controller.activeUploads.isEmpty {
                    Section("Upload Activity") {
                        ForEach(controller.activeUploads) { upload in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(upload.filename)
                                        .font(.headline)
                                        .lineLimit(2)

                                    Spacer()

                                    Text(uploadStatusText(upload))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(upload.failureMessage == nil ? Color.secondary : Color.red)
                                }

                                if let failureMessage = upload.failureMessage {
                                    Text(failureMessage)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else {
                                    ProgressView(value: upload.isImporting ? 1 : upload.progress)

                                    HStack(spacing: 12) {
                                        Text(uploadProgressText(upload))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        if upload.isUploading {
                                            Text(formattedTransferRate(upload.speedBytesPerSecond))
                                                .font(.caption)
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Recent Uploads") {
                    if controller.recentUploads.isEmpty {
                        Text("No uploads yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.recentUploads) { upload in
                            VStack(alignment: .leading) {
                                Text(upload.filename)
                                Text(upload.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Upload")
        }
    }

    private func uploadStatusText(_ upload: UploadServerController.ActiveUpload) -> String {
        if upload.isImporting {
            return "Importing..."
        }

        if upload.failureMessage != nil {
            return "Failed"
        }

        return "\(Int(upload.progress * 100))%"
    }

    private func uploadProgressText(_ upload: UploadServerController.ActiveUpload) -> String {
        let received = ByteCountFormatter.string(fromByteCount: upload.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: upload.totalBytes, countStyle: .file)
        return "\(received) / \(total)"
    }

    private func formattedTransferRate(_ bytesPerSecond: Double) -> String {
        let roundedRate = Int64(bytesPerSecond.rounded())
        let value = ByteCountFormatter.string(fromByteCount: roundedRate, countStyle: .file)
        return "\(value)/s"
    }
}

private struct SettingsView: View {
    @SwiftUI.AppStorage(ReaderSettings.fontSizeKey) private var fontSize = ReaderSettings.defaultFontSize
    @SwiftUI.AppStorage(ReaderSettings.fontFamilyKey) private var fontFamilyRawValue = ""
    @SwiftUI.AppStorage(ReaderSettings.lineHeightKey) private var lineHeight = ReaderSettings.defaultLineHeight
    @SwiftUI.AppStorage(ReaderSettings.themeKey) private var themeRawValue = AppThemeOption.system.rawValue
    @SwiftUI.AppStorage(ReaderSettings.readAloudColorKey) private var readAloudColorRawValue = ReaderSettings.defaultReadAloudColorHex
    @SwiftUI.AppStorage(ReaderSettings.playbackSpeedKey) private var playbackSpeed = ReaderSettings.defaultPlaybackSpeed

    var body: some View {
        NavigationStack {
            Form {
                Section("Reader") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text(fontSize.formatted(.number.precision(.fractionLength(1))))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { ReaderSettings.normalizedFontSize(fontSize) },
                                set: { fontSize = ReaderSettings.normalizedFontSize($0) }
                            ),
                            in: ReaderSettings.fontSizeRange,
                            step: ReaderSettings.fontSizeStep
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Line Height")
                            Spacer()
                            Text(lineHeight.formatted(.number.precision(.fractionLength(1))))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { ReaderSettings.normalizedLineHeight(lineHeight) },
                                set: { lineHeight = ReaderSettings.normalizedLineHeight($0) }
                            ),
                            in: ReaderSettings.lineHeightRange,
                            step: ReaderSettings.lineHeightStep
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Playback Speed")
                            Spacer()
                            Text(ReaderSettings.playbackSpeedText(playbackSpeed))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { ReaderSettings.normalizedPlaybackSpeed(playbackSpeed) },
                                set: { playbackSpeed = ReaderSettings.normalizedPlaybackSpeed($0) }
                            ),
                            in: ReaderSettings.playbackSpeedRange,
                            step: ReaderSettings.playbackSpeedStep
                        )
                    }

                    Picker("Font Family", selection: $fontFamilyRawValue) {
                        ForEach(ReaderSettings.fontFamilyOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }

                Section("Appearance") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Theme")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(AppThemeOption.allCases) { option in
                                Button {
                                    themeRawValue = option.rawValue
                                } label: {
                                    Text(option.name)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .fill(isThemeSelected(option) ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                                        }
                                        .foregroundStyle(isThemeSelected(option) ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    NavigationLink {
                        ReadAloudColorEditor(colorHex: $readAloudColorRawValue)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                            .navigationTitle("Highlight Color")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        HStack(spacing: 12) {
                            Text("Highlight Color")

                            Spacer()

                            Circle()
                                .fill(ReaderSettings.color(from: readAloudColorRawValue))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle()
                                        .stroke(.black.opacity(0.08), lineWidth: 1)
                                }
                        }
                        .contentShape(Rectangle())
                    }
                }

                Section("Preview") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The quick brown fox jumps over the lazy dog.\nPack my box with five dozen liquor jugs.")
                            .font(.system(size: previewFontSize))
                            .lineSpacing(previewLineSpacing)

                        Text("Read aloud sample")
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ReaderSettings.color(from: readAloudColorRawValue).opacity(0.35))
                            }

                        Text("\(selectedFontFamilyName) • \(selectedAppTheme.name)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .preferredColorScheme(selectedAppTheme.preferredColorScheme)
                }
            }
        }
    }

    private func isThemeSelected(_ option: AppThemeOption) -> Bool {
        selectedAppTheme == option
    }

    private var selectedFontFamilyName: String {
        ReaderSettings.fontFamilyOptions.first(where: { $0.id == fontFamilyRawValue })?.name ?? "Default"
    }

    private var selectedAppTheme: AppThemeOption {
        ReaderSettings.appTheme(from: themeRawValue)
    }

    private var previewFontSize: Double {
        17 * ReaderSettings.normalizedFontSize(fontSize)
    }

    private var previewLineSpacing: Double {
        max(0, ReaderSettings.normalizedLineHeight(lineHeight) - 1) * previewFontSize
    }
}

private struct ReadAloudColorEditor: View {
    @Binding var colorHex: String
    @State private var hexText = ""

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
    private let presetHexValues = [
        "#FF3B30", "#FF6B6B", "#FF2D55", "#D63384", "#AF52DE", "#7C3AED",
        "#5856D6", "#3B82F6", "#0A84FF", "#06B6D4", "#14B8A6", "#10B981",
        "#34C759", "#84CC16", "#A3E635", "#FACC15", "#FF9F0A", "#F97316",
        "#8B5E3C", "#A2845E", "#636366", "#8E8E93", "#C7C7CC", "#E5E5EA",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReadAloudSpectrumView(
                hue: colorHSB.hue,
                saturation: colorHSB.saturation,
                brightness: colorHSB.brightness,
                onChange: updateSpectrumColor
            )

            VStack(alignment: .leading, spacing: 10) {
                ReadAloudHueSlider(
                    hue: colorHSB.hue,
                    onChange: { updateSpectrumColor(hue: $0, saturation: colorHSB.saturation, brightness: colorHSB.brightness) }
                )
            }

            LazyVGrid(columns: swatchColumns, spacing: 10) {
                ForEach(presetHexValues, id: \.self) { presetHex in
                    Button {
                        colorHex = presetHex
                    } label: {
                        Circle()
                            .fill(ReaderSettings.color(from: presetHex))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle()
                                    .stroke(isSelectedSwatch(presetHex) ? Color.primary : Color.black.opacity(0.08), lineWidth: isSelectedSwatch(presetHex) ? 3 : 1)
                            }
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ReaderSettings.color(from: colorHex))
                    .frame(width: 72, height: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.black.opacity(0.08), lineWidth: 1)
                    }

                HStack(spacing: 0) {
                    Text("#")
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    TextField("685C39", text: $hexText)
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onChange(of: hexText) { _, newValue in
                            let normalized = ReaderSettings.normalizedReadAloudColorText(newValue)
                            if normalized != newValue {
                                hexText = normalized
                                return
                            }

                            if let hex = ReaderSettings.readAloudColorHex(from: normalized) {
                                colorHex = hex
                            }
                        }
                        .onSubmit {
                            hexText = ReaderSettings.readAloudColorText(from: colorHex)
                        }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.black.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
            .accessibilityLabel("sRGB Hex")
            .accessibilityValue(readAloudHexDisplay)
            .onTapGesture {
                hexText = ReaderSettings.readAloudColorText(from: colorHex)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            hexText = ReaderSettings.readAloudColorText(from: colorHex)
        }
        .onChange(of: colorHex) { _, newValue in
            let normalized = ReaderSettings.readAloudColorText(from: newValue)
            if normalized != hexText {
                hexText = normalized
            }
        }
    }

    private var colorHSB: ReadAloudColorHSB {
        ReaderSettings.readAloudColorHSB(from: colorHex)
    }

    private func updateSpectrumColor(hue: Double, saturation: Double, brightness: Double) {
        colorHex = ReaderSettings.readAloudColorHex(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )
    }

    private func isSelectedSwatch(_ presetHex: String) -> Bool {
        presetHex == colorHex
    }

    private var readAloudHexDisplay: String {
        "#\(ReaderSettings.readAloudColorText(from: colorHex))"
    }
}

private struct ReadAloudSpectrumView: View {
    let hue: Double
    let saturation: Double
    let brightness: Double
    let onChange: (Double, Double, Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = max(geometry.size.height, 1)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white, hueColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(Circle().fill(currentColor))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .position(
                        x: saturation * width,
                        y: (1 - brightness) * height
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newSaturation = min(max(value.location.x / width, 0), 1)
                        let newBrightness = 1 - min(max(value.location.y / height, 0), 1)
                        onChange(hue, newSaturation, newBrightness)
                    }
            )
        }
        .frame(height: 220)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }

    private var hueColor: Color {
        Color(uiColor: UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))
    }

    private var currentColor: Color {
        Color(uiColor: UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
    }
}

private struct ReadAloudHueSlider: View {
    let hue: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(
                        Circle()
                            .fill(Color(uiColor: UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)))
                    )
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .position(x: hue * width, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(min(max(value.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: 28)
        .overlay {
            Capsule(style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }
}

private extension UTType {
    static let epub = UTType(filenameExtension: "epub") ?? .data
}

#Preview {
    ContentView()
        .modelContainer(for: Book.self, inMemory: true)
}
