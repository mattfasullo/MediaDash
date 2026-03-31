import AppKit

/// Loading + completion sounds for new-docket approval (Work Picture / Simian creation).
enum DocketAddSounds {
    private static var loadingSound: NSSound?

    static func startLoading(enabled: Bool, volume: Float) {
        assert(Thread.isMainThread)
        stopLoading()
        guard enabled, volume > 0 else { return }
        guard let url = Bundle.main.url(forResource: "LoadingDocketSound", withExtension: "wav") else { return }
        let sound = NSSound(contentsOf: url, byReference: true)
        sound?.volume = volume
        sound?.loops = true
        sound?.play()
        loadingSound = sound
    }

    static func stopLoading() {
        assert(Thread.isMainThread)
        loadingSound?.stop()
        loadingSound = nil
    }

    static func playDocketAdded(enabled: Bool, volume: Float) {
        assert(Thread.isMainThread)
        guard enabled, volume > 0 else { return }
        guard let url = Bundle.main.url(forResource: "DocketAddedSound", withExtension: "wav") else { return }
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = volume
        sound.play()
    }
}
