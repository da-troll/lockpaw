import SwiftUI
import UniformTypeIdentifiers

/// Lock Screen: what the cover shows. The mascot and its live preview first, then the
/// message, the other displays and the wallpaper, then fade to black. Sub-options only
/// appear once their parent is on.
struct LockScreenSettingsPane: View {
    @AppStorage(Mascot.storageKey) private var selectedMascot = Mascot.defaultValue
    @AppStorage(SeasonalSkin.enabledKey) private var seasonalMascots = true
    @AppStorage(LockScreenSize.mascotStorageKey) private var mascotSize = LockScreenSize.defaultValue.rawValue
    @AppStorage(LockScreenSize.textStorageKey) private var textSize = LockScreenSize.defaultValue.rawValue
    @AppStorage("showMessage") private var showMessage = true
    @AppStorage("lockMessage") private var message = Constants.defaultLockMessage
    @AppStorage("multiDisplayMode") private var multiDisplayMode = 0 // 0 = Ambient, 1 = Mirror
    @AppStorage(DesktopWallpaper.enabledKey) private var showDesktopWallpaper = DesktopWallpaper.defaultEnabled
    @AppStorage(WallpaperMotion.storageKey) private var wallpaperMotion = WallpaperMotion.defaultValue
    @AppStorage(FadeToBlack.enabledKey) private var fadeToBlackEnabled = FadeToBlack.defaultEnabled
    @AppStorage(FadeToBlack.storageKey) private var fadeToBlackDelay = FadeToBlack.defaultValue

    @AppStorage(GazeController.enabledKey) private var gazeEnabled = GazeController.defaultEnabled
    @AppStorage(MascotFolderController.onlyWithEyesKey) private var folderOnlyWithEyes = MascotFolderController.defaultOnlyWithEyes
    @AppStorage(MascotFolderController.sourceKey) private var customSource = MascotFolderController.imageSource

    @ObservedObject private var customMascot = CustomMascot.shared
    @ObservedObject private var gaze = GazeController.shared
    @ObservedObject private var folder = MascotFolderController.shared
    @ObservedObject private var supporter = Supporter.shared
    @State private var customMascotError: String?

    var body: some View {
        Form {
            Section {
                MascotPreview(
                    mascot: Mascot.effective(from: selectedMascot),
                    showsMessage: showMessage,
                    message: message,
                    mascotSize: LockScreenSize.resolved(from: mascotSize),
                    textSize: LockScreenSize.resolved(from: textSize)
                )
                    .listRowInsets(EdgeInsets())

                if mascotChoices.count > 5 {
                    Picker("Mascot", selection: $selectedMascot) { mascotOptions }
                        .pickerStyle(.menu)
                } else {
                    Picker("Mascot", selection: $selectedMascot) { mascotOptions }
                        .pickerStyle(.segmented)
                }

                // Always straight after the mascot choice, so it doesn't move when Custom
                // adds its rows.
                if Mascot.effective(from: selectedMascot) != .hidden {
                    Picker("Mascot size", selection: $mascotSize) { sizeOptions }
                        .pickerStyle(.segmented)
                }

                if Mascot.resolved(from: selectedMascot) == .custom {
                    Picker("Source", selection: $customSource) {
                        Text("Image").tag(MascotFolderController.imageSource)
                        Text("Folder").tag(MascotFolderController.folderSource)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: customSource) { _, _ in folder.sourceChanged() }

                    if usesFolder {
                        LabeledContent {
                            HStack(spacing: 8) {
                                if folder.folderURL != nil {
                                    Button("Rescan") { folder.rescan() }
                                        .disabled(folder.progress != nil)
                                }
                                Button(folder.folderURL == nil ? "Choose\u{2026}" : "Change\u{2026}") { chooseFolder() }
                            }
                        } label: {
                            SettingLabel(folder.folderURL?.lastPathComponent ?? "Folder", detail: MascotFolder.statusText(folder.state))
                        }
                    } else {
                        LabeledContent {
                            HStack(spacing: 8) {
                                if customMascot.hasImage {
                                    Button("Remove") {
                                        customMascot.remove()
                                        customMascotError = nil
                                    }
                                }
                                Button(customMascot.hasImage ? "Replace\u{2026}" : "Choose\u{2026}") { chooseCustomImage() }
                            }
                        } label: {
                            SettingLabel("Image", detail: customMascotError ?? "PNG, JPEG or HEIC. A transparent background looks best.")
                        }
                    }

                    // Shown from the start in folder mode, not only once an image is ready:
                    // it is a setting for the whole set, and waiting for the folder to be
                    // prepared made it turn up half a minute late.
                    if customMascot.hasImage || usesFolder {
                        Toggle(isOn: gazeBinding) {
                            SettingLabel("Eyes follow passers-by", detail: gazeDetail)
                        }
                        .onAppear {
                            customMascot.refreshEyesInBackground()
                            gaze.refreshAccess()
                        }
                        .onChange(of: gazeEnabled) { _, _ in folder.choiceChanged() }

                        if usesFolder && gazeBinding.wrappedValue {
                            Toggle(isOn: $folderOnlyWithEyes) {
                                SettingLabel("Only images with moving eyes", detail: "Skips the images where no eyes were found.")
                            }
                            .onChange(of: folderOnlyWithEyes) { _, _ in folder.choiceChanged() }
                        }
                    }
                }

                if supporter.isSupporter {
                    Toggle(isOn: $seasonalMascots) {
                        SettingLabel("Seasonal outfits", detail: "The dog and cat dress up for the holidays.")
                    }
                }
            }

            Section("Message") {
                Toggle("Show a message", isOn: $showMessage)
                if showMessage {
                    TextField("Message", text: $message, prompt: Text(Constants.defaultLockMessage), axis: .vertical)
                        .lineLimit(1...3)
                        .onChange(of: message) { _, newValue in
                            if newValue.count > 120 { message = String(newValue.prefix(120)) }
                        }
                }
                // Outside the "Show a message" switch: it sizes the timer and the waiting
                // agents too, which show either way.
                Picker(selection: $textSize) { sizeOptions } label: {
                    SettingLabel("Text size", detail: "The message, the timer and the agents waiting.")
                }
                .pickerStyle(.segmented)
            }

            Section("Background") {
                Toggle(isOn: $showDesktopWallpaper) {
                    SettingLabel("Desktop wallpaper", detail: "Show your wallpaper behind the lock screen, Aerials included.")
                }
                .onChange(of: showDesktopWallpaper) { _, isOn in
                    if isOn { WallpaperController.requestAccessToStills() }
                }

                if showDesktopWallpaper {
                    Picker("Aerials move", selection: $wallpaperMotion) {
                        ForEach(WallpaperMotion.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }

                Picker(selection: $multiDisplayMode) {
                    Text("Ambient").tag(0)
                    Text("Mirror").tag(1)
                } label: {
                    SettingLabel("Other displays", detail: multiDisplayMode == 0 ? "A slow glow. The lock screen stays on the main display." : "The full lock screen on every display.")
                }
                .pickerStyle(.segmented)
            }

            Section("Fade to black") {
                Toggle(isOn: $fadeToBlackEnabled) {
                    SettingLabel("Fade to black when idle", detail: "Saves an OLED screen while you're away. Agent pings still glow.")
                }
                if fadeToBlackEnabled {
                    Picker("After", selection: $fadeToBlackDelay) {
                        ForEach(FadeToBlack.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .settingsPane(.lockScreen)
    }

    /// Dog, Cat, Custom, None; plus the supporter mascots for supporters, when their art ships.
    private var mascotChoices: [Mascot] {
        guard supporter.isSupporter else { return Mascot.freeCases }
        let extras = Mascot.supporterCases.filter { $0.assetName.map(Mascot.bundledAssetExists) ?? false }
        return Array(Mascot.freeCases.prefix(2)) + extras + Array(Mascot.freeCases.dropFirst(2))
    }

    @ViewBuilder
    private var mascotOptions: some View {
        ForEach(mascotChoices) { Text($0.displayName).tag($0.rawValue) }
    }

    @ViewBuilder
    private var sizeOptions: some View {
        ForEach(LockScreenSize.allCases) { Text($0.displayName).tag($0.rawValue) }
    }

    /// The user's choice, shown as on only with the camera granted. Turning it on is where
    /// the camera permission is asked, here in Settings, never on the lock screen.
    ///
    /// Deliberately not tied to whether the current image (or folder) has eyes that can
    /// move: it used to be, and switching from Image to Folder made the switch read off
    /// although nothing had been turned off. Whether anything can move is what the line
    /// under it says; the camera itself still only runs for an image with eyes.
    private var gazeBinding: Binding<Bool> {
        Binding(
            get: { GazeCameraPolicy.settingShowsOn(enabled: gazeEnabled, access: gaze.access) },
            set: { isOn in
                guard isOn else { gazeEnabled = false; return }
                Task { gazeEnabled = await gaze.requestAccess() }
            }
        )
    }

    private var usesFolder: Bool { customSource == MascotFolderController.folderSource }

    /// With a folder, any image in it with eyes will do: the setting is for the whole set,
    /// and an image without eyes simply stays still on the locks it is picked for.
    private var hasMovableEyes: Bool {
        usesFolder ? folder.usable.contains(where: \.hasEyes) : customMascot.eyes != nil
    }

    private var gazeDetail: String {
        if usesFolder {
            if folder.folderURL == nil { return "Choose a folder first." }
            if !hasMovableEyes {
                return folder.progress != nil ? "Looking for eyes\u{2026}" : "None of these images have eyes that can move."
            }
        } else {
            if let rejection = customMascot.eyeRejection { return rejection.message }
            if customMascot.eyes == nil { return "Looking for eyes\u{2026}" }
        }
        if gaze.access == .denied {
            return "Camera access is off. Turn it on in System Settings \u{2192} Privacy & Security \u{2192} Camera."
        }
        return "Uses the camera while locked, so its light stays on. Frames stay on this Mac and are never saved."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of images for the lock screen. Up to \(MascotFolder.maxImages) are used."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder.choose(url)
    }

    private func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Image"
        panel.message = "Choose an image for the lock screen."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try customMascot.install(from: url)
            customMascotError = nil
        } catch {
            customMascotError = error.localizedDescription
        }
    }
}

/// A small, live picture of the lock screen: the mascot in its pool of light, the message
/// under it and the timer. It changes as the settings below it do.
private struct MascotPreview: View {
    let mascot: Mascot
    let showsMessage: Bool
    let message: String
    let mascotSize: LockScreenSize
    let textSize: LockScreenSize

    /// Observed so the preview follows Choose, Replace and Remove: none of them change
    /// this view's inputs.
    @ObservedObject private var customMascot = CustomMascot.shared

    /// The mascot's height here at Small; the other sizes scale it as the lock screen does.
    /// Sized so the Large mascot with Large text still fits the preview.
    private static let mascotHeight: CGFloat = 56

    var body: some View {
        let mascotHeight = Self.mascotHeight * mascotSize.mascotScale
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.035, blue: 0.045), Color(red: 0.005, green: 0.006, blue: 0.01)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(colors: [Color("LockpawTeal").opacity(0.16), .clear], center: .center, startRadius: 4, endRadius: 150)

            VStack(spacing: 10) {
                if customMascot.canShow(mascot) {
                    MascotImage(mascot)
                        .frame(height: mascotHeight)
                        .shadow(color: Color("LockpawTeal").opacity(0.25), radius: 18)
                } else if mascot == .custom {
                    Text("No image chosen")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(height: mascotHeight)
                }
                if showsMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 10 * textSize.textScale, weight: .light))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .padding(.horizontal, 24)
                }
                Text("00:42")
                    .font(.system(size: 9 * textSize.textScale, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: 190)
        .animation(.snappy(duration: 0.25), value: mascotSize)
        .animation(.snappy(duration: 0.25), value: textSize)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the lock screen with \(mascot == .hidden ? "no mascot" : mascot.displayName)")
    }
}
