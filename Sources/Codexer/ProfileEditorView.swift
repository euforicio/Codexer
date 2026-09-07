import AppKit
import CodexerCore
import SwiftUI
import UniformTypeIdentifiers

struct EditProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: CodexerModel
    let profile: CodexProfile

    @State private var name: String
    @State private var iconKind: ProfileIconKind
    @State private var iconValue: String
    @State private var iconColor: String
    @State private var customIconData: Data?
    @FocusState private var nameFocused: Bool

    init(profile: CodexProfile) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _iconKind = State(initialValue: profile.iconKind)
        _iconValue = State(initialValue: profile.iconValue)
        _iconColor = State(initialValue: profile.iconColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Profile")
                .font(.system(size: 19, weight: .semibold))
                .padding(.bottom, 18)

            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                    Text("Profile Icon")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    ProfileIconPreview(
                        name: name,
                        kind: iconKind,
                        value: iconValue,
                        color: iconColor,
                        customIconData: customIconData,
                        existingImageURL: profile.customIconPath,
                        size: 96
                    )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Profile name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .focused($nameFocused)
                            .onSubmit(save)
                            .padding(.bottom, 8)
                        ProfileAppearanceEditor(
                            name: name,
                            iconKind: $iconKind,
                            iconValue: $iconValue,
                            iconColor: $iconColor,
                            customIconData: $customIconData,
                            existingImageURL: profile.customIconPath,
                            compact: false
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

                HStack(spacing: 4) {
                    Text("Provider:")
                    Text(profile.product.displayName)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            .scrollIndicators(.visible)
            .disabled(model.storeMutationInProgress)

            Divider()
                .overlay(AgentDockPalette.divider)

            HStack(spacing: 12) {
                Label("Shortcut and sidebar icons update together.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.errorMessage = nil
                    dismiss()
                }
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .agentDockPrimaryAction()
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || model.storeMutationInProgress)
                if model.storeMutationInProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Saving profile")
                }
            }
            .padding(.top, 10)
        }
        .padding(24)
        .frame(width: 620, height: 400, alignment: .topLeading)
        .background(AgentDockPalette.graphite)
        .onAppear {
            nameFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty, !model.storeMutationInProgress else { return }
        model.updateProfile(
            profile,
            name: trimmedName,
            color: Color(hex: iconColor),
            iconKind: iconKind,
            iconValue: iconValue,
            customIconData: customIconData
        )
    }
}

struct ProfileAppearanceEditor: View {
    let name: String
    @Binding var iconKind: ProfileIconKind
    @Binding var iconValue: String
    @Binding var iconColor: String
    @Binding var customIconData: Data?
    let existingImageURL: URL?
    let compact: Bool
    @State private var imageSelectionError: String?

    private let monograms = ["P", "W", "Y", "C", "D"]
    private let symbols = [
        "briefcase", "person", "star", "flag",
        "paperplane.fill", "chevron.left.forwardslash.chevron.right",
        "terminal", "cylinder", "cloud", "lock"
    ]
    private let colors = [
        "#2563EB", "#4F46E5", "#C026D3", "#E5484D", "#F97316",
        "#F5B82E", "#45BF65", "#2BBFB7", "#8B95A5"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Icon Type", selection: $iconKind) {
                Text("Monogram").tag(ProfileIconKind.monogram)
                Text("Symbol").tag(ProfileIconKind.symbol)
                Text("Image").tag(ProfileIconKind.image)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch iconKind {
            case .monogram:
                optionGrid(monograms, kind: .monogram, columns: 5) { value in
                    Text(value)
                        .font(.system(size: 14, weight: .medium))
                }
            case .symbol:
                optionGrid(symbols, kind: .symbol, columns: 5) { value in
                    Image(systemName: value)
                        .font(.system(size: 14))
                }
            case .image:
                imagePicker
                if let imageSelectionError {
                    Label(imageSelectionError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Accent Color")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: compact ? 10 : 13) {
                    ForEach(colors, id: \.self) { hex in
                        Button {
                            iconColor = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(
                                    width: compact ? 20 : 24,
                                    height: compact ? 20 : 24
                                )
                                .overlay {
                                    if iconColor == hex {
                                        Circle()
                                            .stroke(Color.accentColor, lineWidth: 2)
                                            .padding(-3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Accent color \(hex)")
                        .accessibilityAddTraits(iconColor == hex ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func optionGrid<Label: View>(
        _ values: [String],
        kind: ProfileIconKind,
        columns: Int,
        @ViewBuilder label: @escaping (String) -> Label
    ) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 42), spacing: 8),
                count: columns
            ),
            spacing: 8
        ) {
            ForEach(values, id: \.self) { value in
                Button {
                    iconKind = kind
                    iconValue = value
                } label: {
                    label(value)
                        .frame(maxWidth: .infinity)
                        .frame(height: compact ? 34 : 38)
                        .background(
                            AgentDockPalette.panel,
                            in: .rect(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(
                                    isSelected(value, kind: kind)
                                        ? Color.accentColor
                                        : AgentDockPalette.panelBorder,
                                    lineWidth: isSelected(value, kind: kind) ? 2 : 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: value, kind: kind))
                .accessibilityAddTraits(isSelected(value, kind: kind) ? .isSelected : [])
            }
        }
    }

    private func isSelected(_ value: String, kind: ProfileIconKind) -> Bool {
        guard iconKind == kind else { return false }
        if !iconValue.isEmpty {
            return iconValue == value
        }
        switch kind {
        case .monogram:
            return value == String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        case .symbol:
            return value == "person"
        case .image:
            return false
        }
    }

    private var imagePicker: some View {
        HStack {
            Button("Choose Image…", action: chooseImage)
                .buttonStyle(.bordered)
                .controlSize(.regular)
            if customIconData != nil
                || existingImageURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true
            {
                Label("Image selected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Profile Icon"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = resourceValues.fileSize,
            fileSize <= 10 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url),
            let image = NSImage(data: data),
            image.isValid
        else {
            imageSelectionError = "Choose a valid PNG, JPEG, or HEIC image no larger than 10 MB."
            return
        }
        imageSelectionError = nil
        customIconData = data
        iconKind = .image
    }

    private func accessibilityLabel(for value: String, kind: ProfileIconKind) -> String {
        switch kind {
        case .monogram:
            return "Monogram \(value)"
        case .symbol:
            return "Symbol \(value)"
        case .image:
            return "Image"
        }
    }
}

struct ProfileIconPreview: View {
    let name: String
    let kind: ProfileIconKind
    let value: String
    let color: String
    let customIconData: Data?
    let existingImageURL: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if kind == .image, let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.2)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: color), Color(hex: color).opacity(0.65)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    if kind == .symbol {
                        Image(systemName: value.isEmpty ? "person.fill" : value)
                            .font(.system(size: size * 0.4, weight: .medium))
                    } else {
                        Text(value.isEmpty
                            ? String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
                            : String(value.prefix(1)).uppercased())
                            .font(.system(size: size * 0.48, weight: .medium, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.2))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.2)
                .stroke(.white.opacity(0.14))
        }
        .accessibilityHidden(true)
    }

    private var image: NSImage? {
        if let customIconData, let image = NSImage(data: customIconData), image.isValid {
            return image
        }
        if let existingImageURL, let image = NSImage(contentsOf: existingImageURL), image.isValid {
            return image
        }
        return nil
    }
}
