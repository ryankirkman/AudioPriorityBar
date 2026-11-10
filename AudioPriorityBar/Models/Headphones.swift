import Foundation

/// Keywords used to detect headphone-like devices and auto-categorize them
struct HeadphoneDetection {
    /// Device name keywords that indicate headphones/earbuds. Matched as lowercase
    /// substrings, so each one has to be specific enough not to turn up inside other
    /// words ("ear" is in "UltraGear") or to cover a brand's speakers as well.
    static let keywords: [String] = [
        // Generic terms
        "headphone",
        "headset",
        "earphone",
        "earbud",
        "buds",     // Galaxy Buds, Pixel Buds, LinkBuds, FreeBuds, ...

        // Apple
        "airpods",
        "earpods",
        "powerbeats",
        "beatsx",
        "beats fit",
        "beats flex",
        "beats solo",
        "beats studio",

        // Sony
        "wh-1000",  // WH-1000XM series
        "wf-1000",  // WF-1000XM series
        "inzone",

        // Bose
        "quietcomfort",
        "qc ultra",
        "qc45",
        "qc35",
        "soundsport",

        // Sennheiser
        "momentum",
        "hd 4",
        "hd 5",
        "pxc",

        // Jabra
        "jabra elite",
        "jabra evolve",
        "evolve2",

        // JBL
        "jbl tune",
        "jbl live",
        "jbl tour",
        "jbl reflect",

        // Other brands
        "soundcore liberty",
        "soundcore life",
        "soundcore space",
        "skullcandy",
        "nothing ear",
        "oppo enco",
        "technics eah",
        "b&w px",
        "beoplay h",
        "denon perl",
        "focal bathys",
        "hifiman",
        "shure aonic",
        "audio-technica ath",
        "beyerdynamic",
        "marshall major",
        "marshall monitor",
        "marshall motif",
        "akg k",
        "akg n",
        "plantronics",
        "voyager",
        "razer kraken",
        "razer blackshark",
        "razer barracuda",
        "steelseries arctis",
        "hyperx cloud",
        "logitech g pro",
        "astro a",
        "corsair hs",
        "corsair void",
        "corsair virtuoso",
        "1more",
        "tozo",
        "fiio",
        "moondrop",
    ]

    /// Check if a device name matches headphone patterns
    static func isHeadphone(deviceName: String) -> Bool {
        let nameLower = deviceName.lowercased()
        return keywords.contains { nameLower.contains($0) }
    }
}
