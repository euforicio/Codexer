import CodexerCore
import SwiftUI

struct OverviewView: View {
  @EnvironmentObject private var model: CodexerModel

  var body: some View {
    Group {
      if let profile = model.selectedProfile {
        ProfileOverview(profile: profile)
      } else if let product = model.selectedOfficialProduct {
        OfficialOverview(product: product)
      } else {
        AgentDockEmptyState(
          title: "Choose a Profile",
          systemImage: "person.crop.square.stack",
          description: "Select a provider app or profile in the sidebar, or create a profile for another account.",
          actionTitle: "Add Profile",
          action: { model.showAddProfile = true }
        )
      }
    }
  }
}

private struct ProfileOverview: View {
  @EnvironmentObject private var model: CodexerModel
  @State private var activityDestination: ActivityDestination?
  let profile: CodexProfile

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header

          if profile.lastLaunchedAt == nil {
            Label(
              "Open \(profile.product.displayName), then sign in inside its window to start using this profile.",
              systemImage: "person.crop.circle.badge.plus"
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AgentDockPalette.panel, in: .rect(cornerRadius: 8))
            .padding(.top, 16)
          }

          if profile.product == .codex {
            UsageLimitsCard(
              limits: model.rateLimits(for: profile), accent: Color(hex: profile.iconColor)
            )
            .padding(.top, 18)

            CodexConfigProfileCard(profile: profile)
              .padding(.top, 10)
          } else {
            UsageLimitsCard(
              limits: model.rateLimits(for: profile),
              accent: Color(hex: profile.iconColor),
              providerName: "Claude"
            )
            .padding(.top, 18)
            ClaudeUsageCard(
              stats: model.stats(for: profile),
              loading: model.statsAreLoading(for: profile),
              accent: Color(hex: profile.iconColor)
            )
            .padding(.top, 16)
          }

          activity
            .padding(.top, 20)

          if profile.product == .claude {
            ClaudeUsageSourcesCard(selection: .profile(profile.id))
              .padding(.top, 16)
          }

          Button {
            model.detailTab = .advanced
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
                .frame(width: 24)
              VStack(alignment: .leading, spacing: 2) {
                Text("Advanced")
                  .font(.system(size: 14, weight: .medium))
                Text("Provider app, local data, shortcut, and profile state")
                  .font(.system(size: 12))
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .background {
            OverviewSurfaceCard(cornerRadius: 8)
          }
          .padding(.top, 16)
          .accessibilityHint("Shows advanced profile management")

          Spacer(minLength: 16)
          footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
      }
      .background(AgentDockPalette.graphite)
    }
    .sheet(item: $activityDestination) { destination in
      ActivityDetailSheet(profile: profile, destination: destination)
    }
  }

  private var header: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) {
          profileIdentity
          Spacer(minLength: 12)
          profileActions
        }
        VStack(alignment: .leading, spacing: 16) {
          profileIdentity
          profileActions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 58, alignment: .top)

      Divider()
        .overlay(AgentDockPalette.divider)
        .padding(.top, 14)
    }
  }

  private var profileIdentity: some View {
    let status = model.instanceStatus(for: profile)
    return HStack(spacing: 16) {
      ProfileIconView(profile: profile, size: 54)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 7) {
          Text(profile.name)
            .font(.system(size: 24, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
          Button {
            model.showEditProfile = true
          } label: {
            Image(systemName: "ellipsis")
              .font(.system(size: 13, weight: .semibold))
              .frame(width: 25, height: 22)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Edit Profile")
        }
        Text("Managed \(profile.product.displayName) profile")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack(spacing: 10) {
          StatusDot(isRunning: status.isRunning, size: 8)
          Text(status.isRunning ? "Running" : "Stopped")
          Divider().frame(height: 14)
          Text(lastOpenedText)
            .lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    }
    .frame(minWidth: 230, alignment: .leading)
  }

  private var profileActions: some View {
    let status = model.instanceStatus(for: profile)
    return HStack(spacing: 10) {
      Button {
        model.launch(profile)
      } label: {
        Label(
          status.isRunning
            ? "Focus \(profile.product.displayName)" : "Open \(profile.product.displayName)",
          systemImage: status.isRunning ? "arrow.up.forward.app.fill" : "play.fill"
        )
      }
      .agentDockPrimaryAction()
      .controlSize(.regular)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(model.isBusy(profile))
      .help("\(status.isRunning ? "Focus" : "Open") \(profile.name)")
      .accessibilityLabel("\(status.isRunning ? "Focus" : "Open") \(profile.name) in \(profile.product.displayName)")

      if status.isRunning {
        Button(role: .destructive) {
          model.close(profile)
        } label: {
          Image(systemName: "stop.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help("Close this profile only")
        .accessibilityLabel("Close \(profile.name) only")
        .disabled(model.isBusy(profile))
      }

      if model.isBusy(profile) {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Updating profile")
      }
    }
    .fixedSize()
  }

  private var activity: some View {
    let stats = model.stats(for: profile)
    let loading = model.statsAreLoading(for: profile)
    return VStack(alignment: .leading, spacing: 8) {
      UsageActivityCard(product: profile.product, stats: stats, loading: loading) {
        activityDestination = $0
      }

      if profile.product == .claude {
        Label(
          "Token and activity totals come from this profile's local Cowork history. Limit status is the latest Claude-emitted signal, not a complete quota snapshot.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
      }

      ForEach(stats.errorMessages, id: \.self) { message in
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  private var footer: some View {
    Text("AgentDock \(appVersion) · Stored locally")
    .font(.system(size: 11))
    .foregroundStyle(.tertiary)
    .frame(height: 30, alignment: .bottomLeading)
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "Development"
  }

  private var lastOpenedText: String {
    guard let date = profile.lastLaunchedAt else { return "Never opened" }
    return "Last opened \(date.formatted(date: .abbreviated, time: .shortened))"
  }
}

private struct CodexConfigProfileCard: View {
  @EnvironmentObject private var model: CodexerModel
  let profile: CodexProfile

  var body: some View {
    CompactCodexProviderProfileCard(
      scopeName: profile.name,
      discoveryDescription: "this profile's CODEX_HOME",
      selection: profile.codexLaunchProfileSelection,
      defaultProfile: profile.codexDefaultConfigProfile,
      availableProfiles: model.codexConfigProfiles(for: profile),
      isRunning: model.instanceStatus(for: profile).isRunning,
      isBusy: model.isBusy(profile) || model.storeMutationInProgress,
      onSelect: { model.setCodexLaunchProfileSelection($0, for: profile) },
      onMakeDefault: { model.setDefaultCodexConfigProfile($0, for: profile) }
    )
  }
}

private struct OfficialCodexConfigProfileCard: View {
  @EnvironmentObject private var model: CodexerModel

  var body: some View {
    CompactCodexProviderProfileCard(
      scopeName: "Official Codex",
      discoveryDescription: "the official ~/.codex home",
      selection: model.officialCodexProfileSettings.launchSelection,
      defaultProfile: model.officialCodexProfileSettings.defaultConfigProfile,
      availableProfiles: model.officialCodexConfigProfiles,
      isRunning: model.stockInstanceStatuses[.codex]?.isRunning == true,
      isBusy: model.busyStockProducts.contains(.codex),
      onSelect: model.setOfficialCodexLaunchProfileSelection,
      onMakeDefault: model.setOfficialCodexDefaultConfigProfile
    )
  }
}

private struct CompactCodexProviderProfileCard: View {
  let scopeName: String
  let discoveryDescription: String
  let selection: CodexLaunchProfileSelection
  let defaultProfile: CodexConfigProfile?
  let availableProfiles: [CodexConfigProfile]
  let isRunning: Bool
  let isBusy: Bool
  let onSelect: (CodexLaunchProfileSelection) -> Void
  let onMakeDefault: (CodexConfigProfile?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 10) {
        Label("Provider", systemImage: "switch.2")
          .font(.system(size: 13, weight: .semibold))

        Spacer(minLength: 8)

        Picker("Provider Profile", selection: selectionBinding) {
          Text(defaultLabel).tag(CodexLaunchProfileSelection.useDefault)
          if defaultProfile != nil {
            Text("Built-in Codex (OAuth)").tag(CodexLaunchProfileSelection.builtIn)
          }
          ForEach(profilesIncludingSelection) { configProfile in
            Text(configProfile.displayName).tag(CodexLaunchProfileSelection.named(configProfile))
          }
        }
        .labelsHidden()
        .frame(width: 220)
        .disabled(isBusy)

        Button {
          onMakeDefault(effectiveProfile)
        } label: {
          Label(isDefault ? "Default" : "Make Default", systemImage: isDefault
            ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDefault || effectiveProfileIsUnavailable || isBusy)
        .help("Use this provider profile as the default for \(scopeName)")
      }

      if effectiveProfileIsUnavailable {
        Label(
          "This provider profile is unavailable in \(discoveryDescription).",
          systemImage: "exclamationmark.triangle"
        )
        .font(.system(size: 10.5))
        .foregroundStyle(.orange)
      } else {
        Text(statusDescription)
          .font(.system(size: 10.5))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background { OverviewSurfaceCard(cornerRadius: 8) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Codex provider profile")
  }

  private var selectionBinding: Binding<CodexLaunchProfileSelection> {
    Binding(
      get: {
        defaultProfile == nil && selection == .builtIn ? .useDefault : selection
      },
      set: { onSelect($0) }
    )
  }

  private var defaultLabel: String {
    if let defaultProfile {
      "Default — \(defaultProfile.displayName)"
    } else {
      "Built-in Codex (OAuth) — Default"
    }
  }

  private var profilesIncludingSelection: [CodexConfigProfile] {
    var profiles = availableProfiles
    if case let .named(selected) = selection, !profiles.contains(selected) {
      profiles.append(selected)
    }
    return profiles.sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  private var effectiveProfile: CodexConfigProfile? {
    switch selection {
    case .useDefault: defaultProfile
    case .builtIn: nil
    case let .named(configProfile): configProfile
    }
  }

  private var effectiveProfileIsUnavailable: Bool {
    guard let effectiveProfile else { return false }
    return !availableProfiles.contains(effectiveProfile)
  }

  private var isDefault: Bool {
    effectiveProfile == defaultProfile
  }

  private var statusDescription: String {
    let source: String
    if let effectiveProfile {
      source = "\(effectiveProfile.displayName) from \(discoveryDescription)"
    } else {
      source = "Built-in OAuth"
    }
    return isRunning ? "\(source) · Changing it restarts only this account." : source
  }
}

private struct OfficialOverview: View {
  @EnvironmentObject private var model: CodexerModel
  @State private var activityDestination: ActivityDestination?
  let product: DesktopProduct

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 14) {
          ProviderIconView(product: product, appURL: model.appURL(for: product), size: 54)
          VStack(alignment: .leading, spacing: 3) {
            Text("Official \(product.displayName)")
              .font(.system(size: 24, weight: .semibold))
            Text("Default installation")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            model.openStock(product)
          } label: {
            Label(
              model.stockInstanceStatuses[product]?.isRunning == true
                ? "Focus \(product.displayName)" : "Open \(product.displayName)",
              systemImage: model.stockInstanceStatuses[product]?.isRunning == true
                ? "arrow.up.forward.app.fill" : "play.fill"
            )
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
          .disabled(model.busyStockProducts.contains(product))
          .keyboardShortcut(.return, modifiers: .command)
          .help("Open or focus the official installation")

          if model.busyStockProducts.contains(product) {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Opening official \(product.displayName)")
          }
        }

        Divider().overlay(AgentDockPalette.divider)

        if model.profiles.isEmpty {
          SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
              Label("Your accounts, side by side", systemImage: "person.crop.square.stack")
                .font(.system(size: 16, weight: .semibold))
              Text("Create a profile for another account. Open it and sign in inside the provider app; each profile keeps its supported app state separate.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Button("Add Your First Profile", systemImage: "plus") {
                model.showAddProfile = true
              }
              .agentDockPrimaryAction()
              .controlSize(.regular)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        if product == .codex {
          UsageLimitsCard(limits: model.officialCodexRateLimits, accent: AgentDockPalette.blue)
          OfficialCodexConfigProfileCard()
          UsageActivityCard(
            product: product,
            stats: model.officialCodexStats,
            loading: model.officialStatsLoading
          ) { destination in
            activityDestination = destination
          }
        } else {
          UsageLimitsCard(
            limits: model.officialClaudeRateLimits,
            accent: .orange,
            providerName: "Claude"
          )
          ClaudeUsageCard(
            stats: model.officialClaudeStats,
            loading: model.officialStatsLoading,
            accent: .orange
          )
          UsageActivityCard(
            product: product,
            stats: model.officialClaudeStats,
            loading: model.officialStatsLoading
          ) { destination in
            activityDestination = destination
          }
          if model.profiles.contains(where: { $0.product == .claude }) {
            ClaudeUsageSourcesCard(selection: .official)
          }
          VStack(alignment: .leading, spacing: 6) {
            Label("Claude Desktop local boundary", systemImage: "lock.shield")
              .fontWeight(.medium)
            Text(
              "Managed profiles isolate Claude user data, logs, configuration, and encrypted payload files. Keychain services, permissions, updater state, filesystem, network, shell, Git, and SSH remain shared."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
          .padding(12)
          .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
        }
      }
      .padding(22)
      .frame(maxWidth: 960, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .sheet(item: $activityDestination) { destination in
      ActivityDetailSheet(officialProduct: product, destination: destination)
    }
  }
}

private struct ClaudeUsageCard: View {
  let stats: ProfileStats
  let loading: Bool
  let accent: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel(title: "Claude Usage")
      VStack(spacing: 0) {
        HStack(spacing: 0) {
          metric(title: "Sessions, 7 days", value: loading ? "Loading…" : stats.weeklySessions.formatted())
          Divider().overlay(AgentDockPalette.divider)
          metric(title: "Processed tokens, 7 days", value: loading ? "Loading…" : stats.weeklyTokens.formatted())
          Divider().overlay(AgentDockPalette.divider)
          metric(title: "Token coverage", value: loading ? "Loading…" : coverageText)
        }
        .frame(height: 72)

        Divider().overlay(AgentDockPalette.divider)

        usageLimitSignal

        if !stats.modelUsage.isEmpty {
          Divider().overlay(AgentDockPalette.divider)
          VStack(alignment: .leading, spacing: 8) {
            Text("Models")
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
            ForEach(stats.modelUsage.prefix(3)) { model in
              HStack {
                Text(model.model)
                  .font(.system(size: 12, design: .monospaced))
                  .lineLimit(1)
                Spacer()
                Text("\(model.sessions) sessions · \(model.tokens.formatted()) tokens")
                  .font(.system(size: 11).monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
          .padding(12)
        }
      }
      .background { OverviewSurfaceCard(cornerRadius: 8) }
    }
  }

  private func metric(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 17, weight: .semibold).monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var usageLimitSignal: some View {
    if let signal = stats.latestUsageLimit {
      HStack(spacing: 12) {
        Image(systemName: signal.status == .rejected ? "exclamationmark.octagon.fill" : "gauge.with.dots.needle.50percent")
          .foregroundStyle(signal.status == .rejected ? .red : (signal.status == .warning ? .orange : accent))
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 3) {
          Text(limitTitle(signal))
            .font(.system(size: 13, weight: .medium))
          Text(limitDetail(signal))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        if let percent = signal.usedPercent {
          Text("\(Int(percent.rounded()))% used")
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
    } else {
      Label("No Claude limit signal has been emitted in the scanned local history.", systemImage: "gauge.open.with.lines.needle.33percent")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var coverageText: String {
    guard stats.totalSessions > 0 else { return "No sessions" }
    return "\(stats.tokenizedSessions) of \(stats.totalSessions)"
  }

  private func limitTitle(_ signal: UsageLimitSignal) -> String {
    let bucket = signal.bucket?
      .replacingOccurrences(of: "_", with: " ")
      .capitalized ?? "Usage"
    switch signal.status {
    case .allowed: return "\(bucket) allowed"
    case .warning: return "\(bucket) nearing limit"
    case .rejected: return "\(bucket) limit reached"
    }
  }

  private func limitDetail(_ signal: UsageLimitSignal) -> String {
    var parts = ["Observed \(signal.observedAt.formatted(date: .abbreviated, time: .shortened))"]
    if let reset = signal.resetsAt {
      parts.append("resets \(reset.formatted(date: .omitted, time: .shortened))")
    }
    if signal.isUsingOverage == true { parts.append("using overage") }
    return parts.joined(separator: " · ")
  }
}

private enum ClaudeUsageSelection: Equatable {
  case official
  case profile(CodexProfile.ID)
}

private struct ClaudeUsageSourcesCard: View {
  @EnvironmentObject private var model: CodexerModel
  let selection: ClaudeUsageSelection

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel(title: "Claude Usage Sources")
      VStack(spacing: 0) {
        Button {
          model.selectOfficial(.claude)
        } label: {
          HStack(spacing: 10) {
            ProviderIconView(
              product: .claude,
              appURL: model.appURL(for: .claude),
              size: 30
            )
            VStack(alignment: .leading, spacing: 2) {
              Text("Official Claude")
                .font(.system(size: 13, weight: selection == .official ? .semibold : .regular))
              Text(officialSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(
              isRunning: model.stockInstanceStatuses[.claude]?.isRunning == true,
              size: 7
            )
            Text(model.stockInstanceStatuses[.claude]?.isRunning == true ? "Running" : "Stopped")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 12)
          .frame(height: 50)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)

        if !profiles.isEmpty {
          Divider().overlay(AgentDockPalette.divider)
        }

        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
          Button {
            model.selectProfile(profile.id)
          } label: {
            HStack(spacing: 10) {
              ProfileIconView(profile: profile, size: 30)
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                  .font(.system(
                    size: 13,
                    weight: selection == .profile(profile.id) ? .semibold : .regular
                  ))
                Text(summary(for: profile))
                  .font(.system(size: 11))
                  .foregroundStyle(.secondary)
              }
              Spacer()
              StatusDot(isRunning: model.instanceStatus(for: profile).isRunning, size: 7)
              Text(model.instanceStatus(for: profile).isRunning ? "Running" : "Stopped")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          if index < profiles.count - 1 {
            Divider().overlay(AgentDockPalette.divider)
          }
        }
      }
      .background { OverviewSurfaceCard(cornerRadius: 8) }
    }
  }

  private var profiles: [CodexProfile] {
    model.profiles.filter { $0.product == .claude }
  }

  private func summary(for profile: CodexProfile) -> String {
    let stats = model.stats(for: profile)
    if model.statsAreLoading(for: profile) { return "Loading local usage…" }
    return "\(stats.weeklySessions) sessions · \(stats.weeklyTokens.formatted()) tokens in 7 days"
  }

  private var officialSummary: String {
    if model.officialStatsLoading { return "Loading local usage…" }
    let stats = model.officialClaudeStats
    return "\(stats.weeklySessions) sessions · \(stats.weeklyTokens.formatted()) tokens in 7 days"
  }
}

private struct UsageLimitsCard: View {
  let limits: ProfileRateLimits?
  let accent: Color
  var providerName = "Codex"

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        SectionLabel(title: "Usage Limits")
        Spacer()
        if let plan = limits?.planType, !plan.isEmpty {
          Text(plan.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      VStack(spacing: 0) {
        if let error = limits?.errorMessage {
          Label(error, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if limits == nil {
          HStack {
            ProgressView().controlSize(.small)
            Text("Loading \(providerName) usage limits…")
              .foregroundStyle(.secondary)
            Spacer()
          }
          .padding(.vertical, 10)
        } else if let limits, limits.buckets.isEmpty, limits.credits == nil {
          Text("No \(providerName) usage-limit data is currently available.")
            .foregroundStyle(.secondary)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          if let warning = limits?.warningMessage {
            Label(warning, systemImage: "exclamationmark.triangle")
              .font(.system(size: 11))
              .foregroundStyle(.orange)
              .padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(AgentDockPalette.divider)
          }
          ForEach(Array((limits?.buckets ?? []).enumerated()), id: \.element.id) { index, bucket in
            VStack(spacing: 0) {
              if let primary = bucket.primary {
                LimitRow(
                  icon: "clock",
                  title: windowTitle(primary, bucket: bucket),
                  usage: primary,
                  accent: accent
                )
              }
              if let secondary = bucket.secondary {
                Divider().overlay(AgentDockPalette.divider)
                LimitRow(
                  icon: "calendar",
                  title: windowTitle(secondary, bucket: bucket),
                  usage: secondary,
                  accent: accent
                )
              }
              if index < (limits?.buckets.count ?? 0) - 1 {
                Divider().overlay(AgentDockPalette.divider)
              }
            }
          }
          if let credits = limits?.credits {
            Divider().overlay(AgentDockPalette.divider)
            HStack {
              Label("Extra usage", systemImage: "creditcard")
                .font(.system(size: 13, weight: .medium))
              Spacer()
              Text(credits.balance)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(height: 44)
          }
        }
      }
    }
  }

  private func windowTitle(_ usage: RateLimitWindowUsage, bucket: RateLimitBucket) -> String {
    let window: String
    guard let minutes = usage.windowDurationMins else { return "\(bucket.name) usage" }
    if minutes == 10_080 { window = "Weekly" }
    else if minutes % 1_440 == 0 { window = "\(minutes / 1_440)-day" }
    else if minutes % 60 == 0 { window = "\(minutes / 60)-hour" }
    else { window = "\(minutes)-minute" }
    return bucket.id == "codex" || bucket.id == "claude" ? window : "\(bucket.name) · \(window)"
  }
}

private struct LimitRow: View {
  let icon: String
  let title: String
  let usage: RateLimitWindowUsage
  let accent: Color

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .frame(width: 34, height: 40)
        .background(.secondary.opacity(0.09), in: .rect(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.system(size: 14, weight: .medium))
        Text(resetText)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(width: 190, alignment: .leading)

      ProgressView(value: min(max(usage.usedPercent, 0), 100), total: 100)
        .tint(usage.usedPercent >= 90 ? .red : accent)

      Text("\(Int(usage.usedPercent.rounded()))% used")
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 82, alignment: .trailing)
    }
    .frame(height: 54)
  }

  private var resetText: String {
    guard let date = usage.resetsAt else { return "Reset time unavailable" }
    return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
  }
}

private struct UsageActivityCard: View {
  let product: DesktopProduct
  let stats: ProfileStats
  let loading: Bool
  let onSelect: (ActivityDestination) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel(title: "Activity")
      VStack(spacing: 0) {
        ActivityRow(
          icon: "externaldrive", title: "Storage",
          value: loading
            ? "Loading…"
            : storageSize
        ) {
          onSelect(.storage)
        }
        if product == .codex {
          Divider().overlay(AgentDockPalette.divider).frame(height: 0)
          ActivityRow(
            icon: "doc.text",
            title: "Logs, last 7 days",
            value: loading
              ? "Loading…"
              : "\(stats.weeklyErrors) errors · \(stats.weeklyWarnings) warnings",
            valueColor: stats.weeklyErrors > 0
              ? .red : (stats.weeklyWarnings > 0 ? .orange : .secondary)
          ) {
            onSelect(.logs)
          }
          Divider().overlay(AgentDockPalette.divider).frame(height: 0)
          latestActivityRow
          Divider().overlay(AgentDockPalette.divider).frame(height: 0)
          ActivityRow(
            icon: "archivebox",
            title: "Archived",
            value: loading ? "Loading…" : stats.archivedSessions.formatted()
          ) {
            onSelect(.archived)
          }
        } else {
          Divider().overlay(AgentDockPalette.divider).frame(height: 0)
          ActivityRow(
            icon: "text.bubble",
            title: "Local sessions",
            value: loading ? "Loading…" : stats.totalSessions.formatted()
          ) {
            onSelect(.sessions)
          }
          Divider().overlay(AgentDockPalette.divider).frame(height: 0)
          latestActivityRow
        }
      }
      .background { OverviewSurfaceCard(cornerRadius: 8) }
    }
  }

  private var storageSize: String {
    let formatted = ByteCountFormatter.agentDock.string(fromByteCount: stats.dataBytes)
    return stats.dataSizeIsTruncated ? "At least \(formatted)" : formatted
  }

  private var latestActivityRow: some View {
    ActivityRow(
      icon: "waveform.path.ecg",
      title: "Latest local activity",
      value: loading
        ? "Loading…"
        : stats.lastActivityAt?.formatted(date: .abbreviated, time: .shortened)
          ?? "No activity yet"
    ) {
      onSelect(.lastActivity)
    }
  }
}

private struct ActivityRow: View {
  let icon: String
  let title: String
  let value: String
  var valueColor: Color = .secondary
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
          .frame(width: 24)
        Text(title)
          .font(.system(size: 13))
        Spacer()
        Text(value)
          .font(.system(size: 12))
          .foregroundStyle(valueColor)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 14)
      .frame(height: 46)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityHint("Shows \(title.lowercased()) details")
  }
}

private struct OverviewSurfaceCard: View {
  let cornerRadius: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(AgentDockPalette.panel.opacity(0.42))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(AgentDockPalette.divider.opacity(0.75), lineWidth: 1)
      }
  }
}
