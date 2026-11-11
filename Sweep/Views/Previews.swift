#if DEBUG
import SwiftUI

// Previews use sample data, so they never scan or touch the real disk.

#Preview("Clean Up", traits: .fixedLayout(width: 1180, height: 760)) {
    RootView().environment(AppModel.sample())
}

#Preview("Confirm", traits: .fixedLayout(width: 480, height: 560)) {
    CleanSheet().environment(AppModel.sample(cleanPhase: .confirming))
}

#Preview("Cleaning", traits: .fixedLayout(width: 480, height: 200)) {
    CleanSheet().environment(AppModel.sample(cleanPhase: .cleaning(done: 2, total: 7, current: "Recipe Book")))
}

#Preview("Result", traits: .fixedLayout(width: 480, height: 520)) {
    CleanSheet().environment(AppModel.sample(
        cleanPhase: .finished,
        report: CleanReport(
            results: [CleanResult(id: "x", title: "Simulators", bytes: 4_800_000_000, outcome: .refused("Protected: iCloud Drive is managed by iCloud."))],
            volumeName: "Macintosh HD", expectedBytes: 21_000_000_000, freedBytes: 17_400_000_000, freeAfter: 78_400_000_000, trashedBytes: 0
        )
    ))
}

#Preview("Explore list", traits: .fixedLayout(width: 1180, height: 760)) {
    let model = AppModel.sample(mode: .explore)
    model.explorer.loadSample(volume: model.volumes[0])
    return RootView().environment(model)
}

#Preview("Explore map", traits: .fixedLayout(width: 1180, height: 760)) {
    let model = AppModel.sample(mode: .explore)
    model.explorer.loadSample(volume: model.volumes[0])
    model.explorer.style = .map
    return RootView().environment(model)
}
#endif
