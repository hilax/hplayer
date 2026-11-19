import SwiftUI

/// 「我的 › 播放 › 播放手势」：顶部三组快捷预设（标准 / 防误触 / 刷剧），下方四组单项自定义开关与参数。
/// 与正片播放器、短剧横屏页共用 `PlaybackGestureStore.shared`，修改后即时生效。
struct PlaybackGestureSettingsView: View {
    @ObservedObject private var store = PlaybackGestureStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: PlaybackGestureSettings { store.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                presetSection
                tapSection
                longPressSection
                swipeSection
                screenAndSafetySection
                resetButton
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.contentInset)
            .padding(.vertical, Theme.Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(Theme.pageBackground.ignoresSafeArea())
        .navigationTitle("播放手势")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .designScreen("playback-gestures")
        .animation(Motion.resolved(Motion.snappy, reduceMotion: reduceMotion), value: store.settings)
    }

    // MARK: - 快捷预设（方案 C）

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("快捷预设")
                    .font(Theme.Typo.meta.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, Theme.Space.xs)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if settings.matchingPreset == nil {
                    TagBadge(text: "自定义", style: .neutral)
                }
            }

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Theme.Space.sm))
                : AnyLayout(HStackLayout(spacing: Theme.Space.sm))

            layout {
                ForEach(PlaybackGesturePreset.allCases) { preset in
                    presetCard(preset)
                }
            }

            Text("选好预设后，仍可在下方按习惯微调任意单项，修改后立即生效。")
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Space.xs)
        }
    }

    private func presetCard(_ preset: PlaybackGesturePreset) -> some View {
        let selected = settings.matchingPreset == preset
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        return Button {
            guard !selected else {
                Haptics.tap()
                return
            }
            store.applyPreset(preset)
            HUD.show("已切换为「\(preset.title)」手势", .success)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                HStack(spacing: Theme.Space.xs) {
                    Text(preset.title)
                        .font(Theme.Typo.row.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    CheckBadge(selected: selected, size: 18)
                }
                Text(preset.subtitle)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.surfaceRaised : Theme.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    selected ? Theme.primaryAction : Theme.hairline,
                    lineWidth: selected ? Theme.Stroke.rule : Theme.Stroke.hairline
                )
            }
            .contentShape(shape)
            .hoverEffect(.highlight)
        }
        .buttonStyle(.pressable(scale: 0.97))
        .accessibilityLabel("\(preset.title)，\(preset.subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("mine.playback.gestures.preset.\(preset.rawValue)")
    }

    // MARK: - 分组 1：点按与双击

    private var tapSection: some View {
        SettingsSection(title: "点按与双击", footnote: doubleTapFootnote) {
            SettingRow(icon: .playback, title: "双击画面") {
                GestureMenuPicker(
                    label: "双击画面",
                    selection: $store.settings.doubleTapAction,
                    options: PlaybackDoubleTapAction.allCases,
                    title: \.title,
                    identifier: "mine.playback.gestures.doubleTap"
                )
            }
            if settings.doubleTapAction == .splitSeekAndToggle {
                SettingRow(icon: .seek, title: "双击跳转步长") {
                    GestureMenuPicker(
                        label: "双击跳转步长",
                        selection: $store.settings.doubleTapStep,
                        options: PlaybackDoubleTapStep.allCases,
                        title: \.title,
                        identifier: "mine.playback.gestures.doubleTapStep"
                    )
                }
            }
        }
    }

    private var doubleTapFootnote: String {
        switch settings.doubleTapAction {
        case .splitSeekAndToggle:
            return "画面左 1/3 双击快退、中间播放或暂停、右 1/3 快进，连续双击可累加秒数。"
        case .playPause:
            return "双击画面任意位置即可切换播放或暂停。"
        case .off:
            return "已关闭双击手势，单击画面会立刻呼出或收起控制栏，不再等待双击判定。"
        }
    }

    // MARK: - 分组 2：长按倍速

    private var longPressSection: some View {
        SettingsSection(title: "长按倍速", footnote: "4K 或软解视频最高以 2× 加速播放，以保持音画同步。") {
            SettingRow(icon: .speed, title: "长按临时倍速") {
                Toggle("长按临时倍速", isOn: $store.settings.longPressBoostEnabled)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.playback.gestures.longPressEnabled")
            }
            if settings.longPressBoostEnabled {
                SettingRow(icon: .fast, title: "长按倍率") {
                    GestureMenuPicker(
                        label: "长按倍率",
                        selection: $store.settings.longPressBoostRate,
                        options: PlaybackBoostRateOption.allCases,
                        title: \.title,
                        identifier: "mine.playback.gestures.boostRate"
                    )
                }
                SettingRow(icon: .skip, title: "长按附加手势") {
                    GestureMenuPicker(
                        label: "长按附加手势",
                        selection: $store.settings.longPressExtra,
                        options: PlaybackLongPressExtra.allCases,
                        title: \.title,
                        identifier: "mine.playback.gestures.longPressExtra"
                    )
                }
            }
        }
    }

    // MARK: - 分组 3：滑动控制

    private var swipeSection: some View {
        SettingsSection(title: "滑动控制", footnote: "已屏蔽屏幕上下 44pt 与左右 24pt 边缘区域，避免与系统控制中心和侧滑返回冲突。") {
            SettingRow(icon: .seek, title: "左右滑快进 / 快退") {
                Toggle("左右滑快进 / 快退", isOn: $store.settings.horizontalSeekEnabled)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.playback.gestures.horizontalSeek")
            }
            if settings.horizontalSeekEnabled {
                SettingRow(icon: .tune, title: "横滑灵敏度") {
                    GestureMenuPicker(
                        label: "横滑灵敏度",
                        selection: $store.settings.seekSensitivity,
                        options: PlaybackSeekSensitivity.allCases,
                        title: \.title,
                        identifier: "mine.playback.gestures.seekSensitivity"
                    )
                }
                SettingRow(icon: .close, title: "下滑取消跳转", subtitle: "拖动进度时向下滑即可撤销本次跳转") {
                    Toggle("下滑取消跳转", isOn: $store.settings.pullDownToCancelSeek)
                        .labelsHidden()
                        .tint(Theme.accentFill)
                        .accessibilityIdentifier("mine.playback.gestures.pullDownCancel")
                }
            }
            SettingRow(icon: .brightnessHigh, title: "左侧上下滑") {
                GestureMenuPicker(
                    label: "左侧上下滑",
                    selection: $store.settings.leftVerticalAction,
                    options: PlaybackVerticalAxisAction.allCases,
                    title: \.title,
                    identifier: "mine.playback.gestures.leftVertical"
                )
            }
            SettingRow(icon: .volumeHigh, title: "右侧上下滑") {
                GestureMenuPicker(
                    label: "右侧上下滑",
                    selection: $store.settings.rightVerticalAction,
                    options: PlaybackVerticalAxisAction.allCases,
                    title: \.title,
                    identifier: "mine.playback.gestures.rightVertical"
                )
            }
            if settings.hasAnyVerticalAction {
                SettingRow(icon: .tune, title: "亮度 / 音量灵敏度") {
                    GestureMenuPicker(
                        label: "亮度 / 音量灵敏度",
                        selection: $store.settings.levelSensitivity,
                        options: PlaybackLevelSensitivity.allCases,
                        title: \.title,
                        identifier: "mine.playback.gestures.levelSensitivity"
                    )
                }
            }
        }
    }

    // MARK: - 分组 4：画面与防误触

    private var screenAndSafetySection: some View {
        SettingsSection(title: "画面与防误触") {
            SettingRow(icon: .aspect, title: "双指捏合画面") {
                GestureMenuPicker(
                    label: "双指捏合画面",
                    selection: $store.settings.pinchAction,
                    options: PlaybackPinchAction.allCases,
                    title: \.title,
                    identifier: "mine.playback.gestures.pinch"
                )
            }
            SettingRow(
                icon: .fullscreen,
                title: "竖屏小窗禁用竖滑",
                subtitle: "竖屏浏览简介和选集时，防止误调亮度或音量"
            ) {
                Toggle("竖屏小窗禁用竖滑", isOn: $store.settings.disableVerticalInPortrait)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.playback.gestures.disableVerticalPortrait")
            }
            SettingRow(
                icon: .lock,
                title: "锁屏禁用全部手势",
                subtitle: "开启后锁定画面不再响应横滑快进和长按倍速"
            ) {
                Toggle("锁屏禁用全部手势", isOn: $store.settings.lockDisablesAllGestures)
                    .labelsHidden()
                    .tint(Theme.accentFill)
                    .accessibilityIdentifier("mine.playback.gestures.lockDisablesAll")
            }
        }
    }

    // MARK: - 恢复默认

    private var resetButton: some View {
        Button {
            store.resetToDefaults()
            HUD.show("已恢复默认播放手势", .success)
        } label: {
            Label("恢复默认手势", icon: .refresh)
        }
        .buttonStyle(SecondaryActionStyle())
        .disabled(settings.isDefault)
        .accessibilityIdentifier("mine.playback.gestures.reset")
    }
}

private struct GestureMenuPicker<Option: Hashable & Identifiable>: View {
    let label: String
    @Binding var selection: Option
    let options: [Option]
    let title: KeyPath<Option, String>
    let identifier: String

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options) { option in
                Text(option[keyPath: title]).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(Theme.textSecondary)
        .accessibilityIdentifier(identifier)
    }
}
