# App Store screenshots

Final, composed store images go in `en-US/` — `fastlane store_screenshots`
uploads everything here, inferring the device class from pixel size:

| Device class | Pixels | Orientation | Count |
| --- | --- | --- | --- |
| Apple Vision Pro | **3840 × 2160** | landscape (only size accepted) | up to 10 |
| iPad 13" | **2752 × 2064** | landscape (or 2064 × 2752 portrait) | up to 10 |

Don't put raw simulator captures here. The pipeline is:

1. Capture raw screens per `docs/appstore/screenshots-plan.md` into
   `Tools/appstore/raw/` (git-ignored).
2. `Tools/appstore/compose.sh` renders the captioned frames at exact store
   sizes into `Tools/appstore/out/` and copies them here with sortable names
   (`01-…` … `NN-…`; App Store order = alphabetical order).

App Preview **videos** are not uploaded by deliver — upload those manually in
App Store Connect (visionOS 3840×2160; iPad 1600×1200; 15–30 s, H.264).
